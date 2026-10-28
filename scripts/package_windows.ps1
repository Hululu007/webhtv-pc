# WebHTV PC · Windows 便携包打包器
#
# 供 GitHub Actions 与本地复现共用：把 `flutter build windows --release` 的
# 产物、sidecar 宿主脚本、构建元数据打成可解压即用的 zip，并输出
# SHA256SUMS.txt / release-info.json。
#
# 设计约束（docs/webhtv-pc-design.md §20.3）：
#   - 只打包主程序、播放器 native 库、sidecar 宿主；**不打包站点源、用户配置、
#     测试 fixture（sidecars/*/spiders、manifests）**；
#   - 必须输出可复现的版本号、构建时间、Git revision、平台标识与签名状态；
#   - 缺任何一个 sidecar 宿主都必须失败，不允许静默产出降级包。
#
# 用法示例：
#   pwsh -File scripts/package_windows.ps1 `
#     -BuildDir apps/desktop-flutter/build/windows/x64/runner/Release `
#     -OutputDir dist `
#     -Version 0.1.0 -BuildNumber 1 -Channel stable `
#     -Commit (git rev-parse HEAD) -FlutterVersion 3.47.5

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$BuildNumber = '',

    [ValidateSet('stable', 'beta', 'dev')]
    [string]$Channel = 'stable',

    [string]$Tag = '',

    [string]$Commit = '',

    [string]$ShortCommit = '',

    [string]$FlutterVersion = '',

    [string]$BuiltAt = '',

    [string]$NotesFile = '',

    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Message) {
    throw "打包失败：$Message"
}

if (-not $IsWindows) {
    Fail '该脚本只适用于 Windows（Authenticode / Compress-Archive 均是 Windows 语义）。'
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "非法版本号 '$Version'，期望 x.y.z（来自 apps/desktop-flutter/pubspec.yaml）。"
}

$buildNumberValue = 0
if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) {
    if ($BuildNumber -notmatch '^\d+$') {
        Fail "非法 build number '$BuildNumber'。"
    }
    $buildNumberValue = [int]$BuildNumber
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not (Test-Path -LiteralPath $BuildDir -PathType Container)) {
    Fail "构建目录不存在：$BuildDir（先执行 flutter build windows --release）。"
}
$BuildDir = (Resolve-Path -LiteralPath $BuildDir).Path

$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$outputRoot = [IO.Path]::GetPathRoot($OutputDir).TrimEnd('\')
if ($OutputDir.TrimEnd('\') -eq $outputRoot) {
    Fail "拒绝把输出目录设为盘符根：$OutputDir"
}
if ($OutputDir.TrimEnd('\') -eq $RepoRoot.TrimEnd('\')) {
    Fail "拒绝把仓库根当作输出目录（会清空工作区）：$OutputDir"
}
if (($BuildDir + '\').StartsWith($OutputDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Fail "输出目录不能是构建目录的上级：$OutputDir"
}

$exeName = 'webhtv_pc.exe'
$exePath = Join-Path $BuildDir $exeName
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Fail "构建目录缺少 $exeName：$BuildDir"
}

# 发行包只带宿主入口及其同目录必需文件；manifests/spiders 是测试 fixture，不得入包。
$sidecarFiles = @(
    'sidecars/spider-host-python/host.py',
    'sidecars/spider-host-python/webhtv_ipc.py',
    'sidecars/spider-host-python/webhtv_catvod.py',
    'sidecars/spider-host-python/base/__init__.py',
    'sidecars/spider-host-python/base/spider.py',
    'sidecars/spider-host-js/host.js',
    'sidecars/spider-host-js/sandbox_worker.js',
    'sidecars/spider-host-jvm/host.jar'
)
foreach ($relative in $sidecarFiles) {
    $source = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Fail "缺少 sidecar 宿主文件：$relative（发行包必须能定位到 sidecar 宿主）。"
    }
}

$suffix = switch ($Channel) {
    'beta' { '-beta' }
    'dev' { '-dev' }
    default { '' }
}
$folderName = "WebHTV-PC-$Version$suffix-windows-x64"
$zipName = "webhtv-pc-$Version$suffix-windows-x64.zip"

if ([string]::IsNullOrWhiteSpace($BuiltAt)) {
    $BuiltAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($Commit)) {
        Fail '无法确定 Git commit；请显式传 -Commit。'
    }
    $Commit = $Commit.Trim()
}
if ([string]::IsNullOrWhiteSpace($ShortCommit)) {
    $ShortCommit = $Commit.Substring(0, [Math]::Min(7, $Commit.Length))
}

$utf8 = [Text.UTF8Encoding]::new($false)

Write-Host "WebHTV PC 打包：version=$Version build=$buildNumberValue channel=$Channel commit=$ShortCommit"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Get-ChildItem -LiteralPath $OutputDir -Force | Remove-Item -Recurse -Force

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('webhtv-pkg-' + [Guid]::NewGuid().ToString('N'))
$staging = Join-Path $stagingRoot $folderName

try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    # 1. 主程序与播放器 native 库
    Copy-Item -Path (Join-Path $BuildDir '*') -Destination $staging -Recurse -Force

    # 2. sidecar 宿主（与 exe 同级；spider_registry.dart 的发行包布局）
    foreach ($relative in $sidecarFiles) {
        $destination = Join-Path $staging $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $destination -Force
    }

    # 3. 签名状态以 Authenticode 实测为准，不靠发布脚本开关猜。
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $staging $exeName)
    $statusText = if ($signature) { $signature.Status.ToString() } else { 'UnknownError' }
    $signatureStatus = if ($statusText -eq 'Valid') {
        'valid'
    } elseif ($statusText -eq 'NotSigned') {
        'unsigned'
    } else {
        'invalid'
    }
    $signatureSubject = $null
    if ($signature -and $signature.SignerCertificate) {
        $signatureSubject = $signature.SignerCertificate.Subject
    }
    $signatureLabel = switch ($signatureStatus) {
        'valid' { '已签名（Authenticode 校验通过）' }
        'unsigned' { '未签名' }
        default { "签名无效（$statusText）" }
    }

    # 4. 构建信息（UTF-8 无 BOM，中文可读）
    $buildInfo = @"
WebHTV PC 构建信息
==================
版本：$Version (build $buildNumberValue)
通道：$Channel
Git commit：$Commit
构建时间（UTC）：$BuiltAt
Flutter：$FlutterVersion
平台：Windows x64
签名：$signatureLabel
程序：$exeName

Sidecar 宿主（随包）：Python / Node / JVM
- 仅包含宿主入口脚本，不捆绑解释器/运行时。
- 对应站源需要本机安装 Python 3、Node 或 JDK 17+；缺失时应用会明确提示「运行时未安装」。
- 第三方许可见 data/flutter_assets/NOTICES.Z。
"@
    [IO.File]::WriteAllText((Join-Path $staging 'BUILD_INFO.txt'), $buildInfo + "`n", $utf8)

    # 5. 随包文件清单（动态库版本 + SHA-256；不逐项列 flutter_assets）
    $inventory = [System.Collections.Generic.List[string]]::new()
    $inventory.Add('随包文件清单（主程序 / 动态库 / Sidecar 宿主）')
    $inventory.Add('flutter_assets 内的资源与第三方许可不逐项列出；许可见 data/flutter_assets/NOTICES.Z。')
    $inventory.Add('')

    $targets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    Get-ChildItem -LiteralPath $staging -File |
        Where-Object { $_.Name -notin @('BUILD_INFO.txt', 'THIRD_PARTY.txt') } |
        ForEach-Object { $targets.Add($_) }
    foreach ($relative in @('data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z')) {
        $candidate = Join-Path $staging $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $targets.Add((Get-Item -LiteralPath $candidate))
        }
    }
    foreach ($relative in $sidecarFiles) {
        $targets.Add((Get-Item -LiteralPath (Join-Path $staging $relative)))
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in ($targets | Sort-Object -Property FullName)) {
        if (-not $seen.Add($file.FullName)) { continue }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $relative = [IO.Path]::GetRelativePath($staging, $file.FullName).Replace('\', '/')
        $fileVersion = $file.VersionInfo.FileVersion
        $versionLabel = if ([string]::IsNullOrWhiteSpace($fileVersion)) { '未知' } else { $fileVersion }
        $inventory.Add(('{0}  sha256={1}  version={2}' -f $relative, $hash, $versionLabel))
    }
    [IO.File]::WriteAllText(
        (Join-Path $staging 'THIRD_PARTY.txt'),
        (($inventory -join "`n") + "`n"),
        $utf8
    )

    # 6. zip（含顶层目录，解压即得可运行目录）
    $zipPath = Join-Path $OutputDir $zipName
    Compress-Archive -LiteralPath $staging -DestinationPath $zipPath -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Fail "zip 未生成：$zipPath"
    }
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # 7. 校验文件（LF 行尾，sha256sum -c 兼容）
    [IO.File]::WriteAllText(
        (Join-Path $OutputDir 'SHA256SUMS.txt'),
        "$zipHash  $zipName`n",
        $utf8
    )

    # 8. 机器可读发布元数据（供未来 updater / 分发使用；当前应用不消费）
    $notes = ''
    if (-not [string]::IsNullOrWhiteSpace($NotesFile) -and (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
        $notes = (Get-Content -LiteralPath $NotesFile -Raw -Encoding utf8)
    }
    $info = [ordered]@{
        schema      = 1
        product     = 'WebHTV PC'
        version     = $Version
        build       = $buildNumberValue
        channel     = $Channel
        tag         = if ([string]::IsNullOrWhiteSpace($Tag)) { $null } else { $Tag }
        commit      = $Commit
        shortCommit = $ShortCommit
        builtAt     = $BuiltAt
        platform    = 'windows'
        arch        = 'x64'
        flutter     = $FlutterVersion
        signature   = [ordered]@{
            status  = $signatureStatus
            subject = $signatureSubject
        }
        assets      = @(
            [ordered]@{
                name   = $zipName
                size   = (Get-Item -LiteralPath $zipPath).Length
                sha256 = $zipHash
            }
        )
        runtimes    = [ordered]@{
            bundledHosts = @('python', 'node', 'jvm')
            requiresLocal = @('Python 3', 'Node', 'JDK 17+')
        }
        notes       = $notes
    }
    $json = ($info | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText((Join-Path $OutputDir 'release-info.json'), $json + "`n", $utf8)

    Write-Host "打包完成：$zipPath"
    Write-Host "SHA256：$zipHash"
    Write-Host "校验文件：$(Join-Path $OutputDir 'SHA256SUMS.txt')"
    Write-Host "发布元数据：$(Join-Path $OutputDir 'release-info.json')"
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
