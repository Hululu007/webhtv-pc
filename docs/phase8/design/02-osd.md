# 02 · 屏显（OSD）

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：`F:\Workspace\webtv4\webhtv\app\src\main\java\com\fongmi\android\tv\ui\custom\PlayerOsdController.java`、
  `app\src\main\res\layout\view_player_osd.xml`
- 关联：`00` §4.1、`01` §6、`03`、`05`
- PC 端落点：新增 `apps/desktop-flutter/lib/ui/player_osd.dart`、
  `apps/desktop-flutter/lib/core/osd_config.dart`；
  修改 `apps/desktop-flutter/lib/services/ui_preferences_store.dart`

---

## 1. 目标

把"关于这次播放的事实"从**对话框**（要主动打开、会遮挡）变成**常驻可选的角标层**，
并提供一个可切换的**诊断面板**承接现有 `_showMediaInfo` / `_showDiagnostics` 的内容。

---

## 2. 上游契约（逐条对应）

| 上游事实 | 位置 | PC 端落点 |
| --- | --- | --- |
| 四角文本：上左标题/分辨率、上右时钟、下左进度、下右网速 | `view_player_osd.xml:17-85` | §3.1 |
| 顶部诊断面板（宽 0.98 视口、高上限 0.84） | `view_player_osd.xml:89-143` | §3.2 |
| 底部 2dp 迷你进度条 | `view_player_osd.xml:145-151` | §3.3 |
| 内边距 14dp | `view_player_osd.xml:15` | §3.4 |
| 文本 14sp + `tnum` + 阴影描边（无底色块） | `view_player_osd.xml:24-30` | §3.5 |
| 刷新周期 1000ms | `PlayerOsdController.java:193` | §4.1 |
| 控制栏可见 → 强制显示 标题/分辨率/时钟，隐藏其余 | `PlayerOsdController.java:208-220` | §4.2 |
| 控制栏隐藏 → 按开关显示 | `PlayerOsdController.java:222-244` | §4.2 |
| 直播时隐藏进度与迷你条 | `PlayerOsdController.java:280, 356` | §3.1、§3.3 |
| 7 个开关，默认 `size`/`progress`/`title` = true | `PlayerSetting.java:562-563`、`508-560` | §5 |
| 诊断面板在横屏时分为主列 + 附加列 | `view_player_osd.xml:104-141` | §3.2 |

---

## 3. 屏显元素

### 3.1 四角

| 角 | 内容 | 数据来源 | 缺失时 |
| --- | --- | --- | --- |
| 上左 | `片名 · 第 N 集`（换行）`3840×2160` | `_request.vodName` / `episodeName`；`controller.videoWidth/Height` | 分辨率未知 → 只显示标题一行 |
| 上右 | `HH:mm:ss` 时钟 | 系统时间 | 不会缺失 |
| 下左 | `00:12:34 / 01:58:20` | `controller.position` / `duration` | `duration <= 0` → **整项隐藏**（上游同） |
| 下右 | `12.8 MB/s` | 需要新增采样（§3.6） | 未采样 → **整项隐藏**（上游同） |

**直播时**：下左与下右的进度类信息隐藏（上游 `isLive()` 判定）。
PC 端的"直播"判据 = `_request.directUrl == true`（`player_page.dart:106` 的既有语义）。

### 3.2 诊断面板

对齐上游的**两列**结构：

| 列 | 内容 | 宽度 |
| --- | --- | --- |
| 主列 | 结论 / 视频 / 音频 / 网络 / 状态 / 播放 / 来源 | 0.98 × 视口宽 × 权重 1.25 |
| 附加列 | 设备 / 系统 / 芯片 / 屏幕 / 网络环境（**PC 端只有部分有对应**） | 权重 1 |

**PC 端主列内容**（全部来自既有 `PlaybackDiagnostics` 与 `PlayerController`，
`lib/core/playback_diagnostics.dart` 已有 `report` 字符串，但那是**面向粘贴**的文本，
面板需要**结构化**的行）：

| 行 | 内容 | 来源 |
| --- | --- | --- |
| 结论 | 正常 / 失败 + 分类 | `diagnostics.succeeded` / `failureKind` |
| 视频 | `codec WxH @fps bitrate` | `controller.selectedVideoTrack`、`videoWidth/Height` |
| 音频 | `codec Nch NHz bitrate` | `controller.selectedAudioTrack`、`audioParams` |
| 网络 | 目标主机 + 格式 | `diagnostics.target`、`diagnostics.format` |
| 状态 | 位置 / 时长 / 缓冲 / 缓冲百分比 | `controller.position/duration/buffered` |
| 播放 | 引擎 / 倍速 / 音量 / 静音 | `PlaybackEngine.mediaKit`、`controller.rate/volume/muted` |
| 来源 | 线路 / 站点 / 剧集 | `_request.flag/siteKey/episodeName` |

**PC 端附加列**：上游的设备/系统/芯片/屏幕在 PC 上没有对应物，
**不得伪造**（`00` §5 第 7 条）。改为：

| 行 | 内容 | 来源 |
| --- | --- | --- |
| 运行环境 | `Windows <version> / <arch>` | 需要新增（`Platform.operatingSystemVersion`） |
| 窗口 | `<W>×<H> @<dpr>` | `MediaQuery.sizeOf` / `devicePixelRatio` |
| 主题 | 暗色 / 亮色 / 跟随系统 | `state.themeMode` |
| 代理 | 本地代理端口 | `state` 的代理状态（若已暴露；否则**整行不显示**） |

**关键纪律**：附加列里**任何拿不到的行都不显示**，而不是显示「未知」。
理由：附加列是"环境快照"，一行「未知」不提供任何信息，只占高度。

### 3.3 迷你进度条

- 位置：画面**最底部**，`height: 2`，`Positioned(left:0, right:0, bottom:0)`。
- 颜色：已播部分 `AppPalette.magnitude`（星等琥珀），未播部分透明。
- **只在控制栏隐藏时显示**（上游同，`PlayerOsdController.java:356`）。
- 直播时隐藏。
- `duration <= 0` 时隐藏。

**为什么用星等琥珀**：`DESIGN.md` 的 The One Accent Rule 说琥珀只用在"真正是星等"的地方，
并明确列举"进度条"是合法用途之一（`DESIGN.md:206`：「选中态（NavigationRail 选中图标、
Chip 选中底、Slider 活动轨、**进度条**、光标与选区）」）。迷你进度条与底部滑杆是同一个语义。

### 3.4 内边距

上游 14dp。PC 端用 `AppSpace.lg`（16px）——**不引入新散值**
（`DESIGN.md` Do: 用 `AppSpace` 的标度值，不要引入新的散值）。
16 vs 14 的差异不影响观感，而 14 会成为全站第 17 个间距值。

**例外**：迷你进度条贴底，无内边距。

### 3.5 可读性

上游用 `shadowColor + shadowDx/Dy/Radius`（阴影描边），**没有底色块**。
PC 端同样：

```dart
TextStyle(
  fontSize: 14,                       // 显式指定，不改 textTheme
  fontFeatures: kTabularFigures,      // 数字成列（DESIGN.md The Tabular-Only-Where-Aligned Rule）
  color: Colors.white,
  shadows: [Shadow(color: Colors.black, offset: Offset(1.5, 1.5), blurRadius: 2)],
)
```

| 纪律 | 理由 |
| --- | --- |
| **字号显式指定 14**，不通过 `textTheme` | `DESIGN.md` The Metric-Neutral Rule：改 `textTheme` 会移动所有页面里不带 `ensureVisible` 的 `tap` |
| **必须 `tabular`** | 时钟与进度每秒刷新，比例字形会让整行左右抖动 |
| **必须描边** | 亮画面（实测 fixture 是高饱和彩条）上纯白字不可读 |
| 不用半透明黑底块 | 四角各一块黑底会在画面上形成四个"洞"，上游的选择是对的 |

**对比度**：白字 + 黑描边在任意底色上都能达到 4.5:1（描边提供局部对比）。
这是**唯一**允许"不依赖主题色"的文本——因为它的背景是任意视频帧，不是主题表面。

### 3.6 网速采样（下右）

**这是本轮唯一需要新写的数据采集。**

上游用 `PlaybackSpeedMeter`（`PlayerOsdController.java:82, 398-400`）按秒采样字节数。
PC 端的 `PlayerController` 目前**没有**字节级吞吐量。

| 方案 | 可行性 | 结论 |
| --- | --- | --- |
| media-kit 暴露吞吐量 | ❌ 未暴露 | 不可用 |
| 从 `buffered` 位置差推算 | ⚠️ 只在缓冲前进时有效，且是**媒体时间**不是字节 | 不可靠 |
| 本地代理统计字节 | ⚠️ 只覆盖走代理的流量（T4 站点），直连站点统计不到 | 覆盖不全 |
| **不实现网速** | ✅ | **本轮选择** |

**决策：本轮不实现下右网速。** 理由：

1. `PRODUCT.md` §Product Principles 第 2 条要求"失败必须如实"，
   而一个只覆盖部分流量的网速读数**会误导**（用户看到 0 会以为卡了，其实只是没走代理）。
2. 上游的 `PlaybackSpeedMeter` 依赖 `PlayerManager` 的引擎级字节计数，
   PC 端没有等价物，伪造一个近似值违反第 5 条"不承诺能力范围"。
3. 下右位置**保留在设计中**，作为后续接入点；本轮该位置**不渲染**。

**这条必须在证据里如实写明**（`05` §6），不得让"屏显做完了"暗示网速也有。

---

## 4. 与控制栏的联动

### 4.1 刷新周期

| 项 | 周期 | 理由 |
| --- | --- | --- |
| 时钟 | 1000ms | 对齐上游 |
| 进度（下左） | 1000ms | 对齐上游 |
| 诊断面板 | 1000ms | 对齐上游 |
| 迷你进度条 | **随 `controller` 通知**（约 250ms） | 2dp 的条按秒跳会显得卡顿；它已经在重建链上，无额外成本 |

**实现**：一个 `Timer.periodic(1s)` 驱动时钟/进度/诊断；
迷你条直接读 `controller.position`（`PlayerPage` 已 `setState`）。

**注意**：`PlayerPage._onControllerChanged` 已经 `setState`（`player_page.dart:348-357`），
屏显层作为其子节点会一起重建。因此屏显**不需要**自己订阅 controller——
只需要一个 1 秒 Timer 刷新"与播放无关"的部分（时钟、诊断采样）。

### 4.2 控制栏可见时的强制显示

对齐上游 `PlayerOsdController.java:208-220`：

| 屏显项 | 控制栏可见 | 控制栏隐藏 |
| --- | --- | --- |
| 上左 标题/分辨率 | **强制显示**（无视开关） | 按开关 |
| 上右 时钟 | **强制显示**（无视开关） | 按开关 |
| 下左 进度 | **强制隐藏** | 按开关 |
| 下右 网速 | **强制隐藏** | （本轮不实现） |
| 诊断面板 | **强制隐藏** | 按开关 |
| 迷你进度条 | **强制隐藏** | 按开关 |

**为什么控制栏可见时要强制显示标题与时钟**：
PC 端的顶栏**有**标题（`AppBar.title`），所以标题不是必需的；
但**时钟**在控制栏里没有对应物，且"现在几点"是看片时的高频需求。

**PC 端的调整**：控制栏可见时**只强制显示时钟**，不强制显示标题
（因为顶栏已经显示了 `vodName · episodeName`，重复显示是噪音）。
这是与上游的**有意差异**，理由写在 `05` §7 的证据里。

### 4.3 屏显全关时的行为

开关全关 + 控制栏隐藏 → 屏显层**完全隐藏**，1 秒 Timer **停止**（不空转）。
对齐上游 `PlayerOsdController.java:222-228`（`return false` 停止重排）。

**但**：控制栏可见时必须重新启动 Timer（为了时钟）。
上游为此专门写了 `setControlsVisible` 里的特判（`PlayerOsdController.java:152-158`），
PC 端同样需要。

---

## 5. 开关与默认值

### 5.1 七项开关

| id | 中文名 | 默认 | 上游键名 |
| --- | --- | --- | --- |
| `title` | 标题 | **true** | `display_title` |
| `size` | 分辨率 | **true** | `display_size` |
| `time` | 时钟 | **true**（PC 新增默认开） | `display_time` |
| `progress` | 播放进度 | **true** | `display_progress` |
| `traffic` | 网速 | false（**本轮无实现**，见 §3.6） | `display_traffic` |
| `mini` | 迷你进度条 | false | `display_mini` |
| `diagnostics` | 诊断面板 | false | `player_osd_diagnostics` |

**与上游的差异（用户已确认）**：上游 `time` 默认 false，PC 端默认 **true**。
理由：PC 是"坐在电脑前"的场景（`PRODUCT.md` §Users），时钟在任务栏之外
多一个来源不构成干扰；而全屏播放时任务栏不可见，时钟是真实需求。

**`traffic` 的处置**：开关**存在但置灰**，副标题写明「本版本未采集网速」。
**不得**让开关可点却无效果——那比没有开关更糟（`DESIGN.md` 关于筛选按钮的同类教训：
"一个点了什么也没有的按钮比没有按钮更糟"）。

### 5.2 持久化

落在 `settings.json` 的 `ui` 段，新增子键：

```json
{
  "ui": {
    "osd": {
      "title": true,
      "size": true,
      "time": true,
      "progress": true,
      "traffic": false,
      "mini": false,
      "diagnostics": false
    }
  }
}
```

**纪律**（沿用 `ui_preferences_store.dart:63-68` 的既有模式）：

| 纪律 | 理由 |
| --- | --- |
| **缺席 = 默认**，不把默认值固化进文件 | 与 `_themeMode` 同一理由：让"从未选过"与"选过默认值"可区分，也不污染既有设置文件 |
| 只接受合法布尔值，非法值回落默认 | 与 `themeMode` 的 `UiThemeMode.normalize` 同语义 |
| 写盘走 `writeSettingsSectionSync` + 串行队列 | 与既有 `_persist` 同一机制（`ui_preferences_store.dart:336-354`），避免与 `SyncState` 的并发写互相踩 |
| 只改 `ui` 段 | 读回时保留 `tmdb` / `sync` 段 |

**新增 API**（`UiPreferencesStore`）：

```dart
/// 生效的屏显开关（缺席项用默认值补齐）。
Map<String, bool> get osdEnabled;

/// 用户是否显式设置过任一屏显开关（决定要不要写盘）。
bool get hasExplicitOsd;

/// 记住单项屏显开关。
Future<bool> rememberOsdFlag(String id, bool enabled);
```

**归一化函数**（纯函数，可单测）：

```dart
/// 把任意输入归一化成完整的 7 项开关表；未知键忽略，缺失键用默认值。
Map<String, bool> normalizeOsdFlags(Object? raw);
```

---

## 6. 屏显与既有对话框的关系

现状有三个对话框承载同类信息（`player_page.dart`）：

| 现状 | 方法 | 本轮处置 |
| --- | --- | --- |
| 媒体信息（12 行表格） | `_showMediaInfo`（1732-1799） | **保留**，作为"完整信息"入口；屏显诊断面板是"快速一瞥" |
| 播放诊断（可复制的文本报告） | `_showDiagnostics`（1802-1833） | **保留**，因为它的核心价值是**复制粘贴**（`Clipboard.setData`），屏显面板做不到 |
| 快捷键说明 | `_showShortcutHelp`（1835-1859） | **保留**，迁入右键菜单（`04`） |

**为什么不全删**：三个对话框都有屏显无法替代的能力——
`_showMediaInfo` 是**结构化 12 行**（屏显面板只有 7 行，且要压字宽）、
`_showDiagnostics` 是**可复制文本**、`_showShortcutHelp` 是**完整快捷键表**。
屏显是**补充**，不是**替代**。

**去重纪律**：屏显面板与 `_showMediaInfo` 显示同一批数据时，
**必须调用同一个纯函数**取数据（见 `05` §3.4 的 `buildOsdDiagnostics`），
否则两处会漂移。

---

## 7. 验收清单

| # | 检查项 | 方式 |
| --- | --- | --- |
| B1 | 7 项开关默认值精确（`title/size/time/progress` = true） | L1 单测 |
| B2 | 归一化：未知键忽略、缺失键补默认、非法类型回落 | L1 单测 |
| B3 | 持久化往返：写入后重新 load 得到同一张表 | L2 单测（临时目录） |
| B4 | 缺席不写盘：从未设置过时 `settings.json` 里没有 `ui.osd` | L2 单测 |
| B5 | 控制栏可见 → 时钟强制显示、进度/迷你/诊断强制隐藏 | L2 widget 测试 |
| B6 | 屏显全关 + 控制栏隐藏 → 层隐藏且 Timer 停止 | L2 widget 测试（`activeTimerCount == 0`） |
| B7 | 直播（`directUrl=true`）→ 进度与迷你条隐藏 | L2 widget 测试 |
| B8 | `duration <= 0` → 进度项隐藏（不显示 `00:00 / 00:00`） | L2 widget 测试 |
| B9 | 屏显层 `IgnorePointer`：点击穿透到画面 | L2 widget 测试 |
| B10 | 屏显文本字号为 14（不来自 `textTheme`） | L1 源码/样式断言 |
| B11 | 诊断面板与 `_showMediaInfo` 用同一取数函数 | L1 单测（函数级） |
| B12 | `traffic` 开关置灰且副标题说明未采集 | L2 widget 测试 |
