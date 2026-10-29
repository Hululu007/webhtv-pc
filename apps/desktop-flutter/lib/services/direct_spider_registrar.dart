/// 直连 `.js` / `.py` 站点的自动注册（`docs/phase9/README.md` P1-7）。
///
/// 安卓允许站点 `api` 直接指向一个 JS/Python 文件；PC 端此前要求用户手工写
/// `spider-local:` manifest。这里把「下载 → 落盘 → 生成 manifest → 注册」自动化，
/// 复用同一套 `webhtv-ipc-v1` sidecar（不新增运行时）。
///
/// 另有第三种形态 [DirectSpiderKind.catVod]：安卓生态里大量站点 `api` 只写壳名
/// （如 `csp_PyProxy`），真正的 Python 蜘蛛地址在 `ext.loader` 里。这类站点
/// 下载 `loader.py` 后生成一个 CatVod 壳入口 `spider.py`，由 sidecar 里的
/// `webhtv_catvod.py` 把 CatVod 语义方法适配成 `webhtv-ipc-v1` 宿主契约。
///
/// 安全与正确性：
/// - 只接受 `http(s)`；
/// - 单文件上限 [maxBytes]（默认 2 MiB），超限拒绝；
/// - 落盘后记录 SHA-256；已存在且哈希一致时**不重复下载**；
/// - 下载/写盘/注册失败只记日志并跳过该站点，不影响其他站点与启动；
/// - 仍然是不可信代码：只在独立 sidecar 中执行，主进程不加载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'spider_registry.dart';

class DirectSpiderRegistrar {
  DirectSpiderRegistrar({
    required this.root,
    required this.registry,
    this.log,
    http.Client? client,
    this.maxBytes = 2 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  /// Spider 根目录；自动注册的产物放在 `<root>/direct/<hash>/`。
  final String root;
  final SpiderManifestRegistry registry;
  final int maxBytes;
  final Duration timeout;

  final LogService? log;
  final http.Client _client;

  /// 扫描配置里的直连 js/py 站点并完成注册。
  ///
  /// 返回「站点 key → LocalSpider」；失败/不支持的站点不出现在结果里。
  Future<Map<String, LocalSpider>> materialize(AppConfig config) async {
    final result = <String, LocalSpider>{};
    for (final site in config.sites) {
      final kind = directSpiderKind(site);
      if (kind == null) continue;
      try {
        final local = await _materializeSite(site, kind);
        if (local != null) result[site.key] = local;
      } catch (error) {
        log?.warning(
          '直连站源注册失败 site=${site.key} api=${redactUrl(site.api)} $error',
          scope: 'spider',
        );
      }
    }
    if (result.isNotEmpty) {
      log?.info('直连站源已注册 ${result.length} 个', scope: 'spider');
    }
    return result;
  }

  Future<LocalSpider?> _materializeSite(Site site, DirectSpiderKind kind) async {
    if (kind == DirectSpiderKind.catVod) {
      return _materializeCatVod(site);
    }
    final api = site.api.trim();
    final uri = Uri.tryParse(api);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    final digest = sha256.convert(utf8.encode(api)).toString();
    final dir = Directory(p.join(root, 'direct', digest.substring(0, 16)));
    final fileName = kind == DirectSpiderKind.js ? 'spider.js' : 'spider.py';
    final entryPath = p.join(dir.path, fileName);
    final manifestPath = p.join(dir.path, 'manifest.json');

    await dir.create(recursive: true);

    String? existingHash;
    final manifestFile = File(manifestPath);
    if (await manifestFile.exists() && await File(entryPath).exists()) {
      final loaded = SpiderManifest.fromJson(
        jsonDecode(await manifestFile.readAsString()),
      );
      existingHash = loaded.entrySha256;
    }

    List<int>? bytes;
    if (await File(entryPath).exists()) {
      bytes = await File(entryPath).readAsBytes();
    }
    final currentHash =
        (bytes == null || bytes.isEmpty) ? '' : sha256.convert(bytes).toString();

    if (bytes == null || bytes.isEmpty || currentHash != existingHash) {
      bytes = await _download(uri);
      if (bytes == null) return null;
      await File(entryPath).writeAsBytes(bytes, flush: true);
    }

    final hash = sha256.convert(bytes).toString();
    final manifest = SpiderManifest(
      key: site.key,
      name: site.name,
      runtime: kind == DirectSpiderKind.js ? 'node' : 'python',
      entry: fileName,
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      entrySha256: hash,
    );
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      flush: true,
    );
    return registry.register(manifestPath);
  }

  /// CatVod 壳（api 只写壳名、真正地址在 ext.loader）。
  ///
  /// 目录键必须带上站点 key：同一份配置里几十个站点的 api 完全一样（如
  /// `csp_PyProxy`），只用 api 做键会互相覆盖。
  Future<LocalSpider?> _materializeCatVod(Site site) async {
    final loaderUrl = catVodLoaderUrl(site);
    if (loaderUrl == null) return null;
    final uri = Uri.tryParse(loaderUrl);
    if (uri == null) return null;

    final digest = sha256
        .convert(utf8.encode('${site.key}\n$loaderUrl'))
        .toString();
    final dir = Directory(p.join(root, 'direct', digest.substring(0, 16)));
    await dir.create(recursive: true);

    final loaderPath = p.join(dir.path, 'loader.py');
    final metaPath = p.join(dir.path, 'loader.json');
    final entryPath = p.join(dir.path, _catVodEntryName);
    final manifestPath = p.join(dir.path, 'manifest.json');

    final loaderFile = File(loaderPath);
    String? loaderHash;
    if (await loaderFile.exists()) {
      final existing = await loaderFile.readAsBytes();
      if (existing.isNotEmpty) {
        loaderHash = sha256.convert(existing).toString();
      }
    }
    String? recordedHash;
    final metaFile = File(metaPath);
    if (await metaFile.exists()) {
      try {
        final meta = jsonDecode(await metaFile.readAsString());
        if (meta is Map) recordedHash = meta['loaderSha256'] as String?;
      } catch (_) {
        recordedHash = null;
      }
    }
    if (loaderHash == null || loaderHash != recordedHash) {
      final bytes = await _download(uri);
      if (bytes == null) return null;
      await loaderFile.writeAsBytes(bytes, flush: true);
      loaderHash = sha256.convert(bytes).toString();
    }
    await metaFile.writeAsString(
      jsonEncode({'loaderUrl': loaderUrl, 'loaderSha256': loaderHash}),
      flush: true,
    );

    final entry = File(entryPath);
    if (!await entry.exists() || await entry.readAsString() != _catVodEntry) {
      await entry.writeAsString(_catVodEntry, flush: true);
    }

    final hash = sha256.convert(utf8.encode(_catVodEntry)).toString();
    final manifest = SpiderManifest(
      key: site.key,
      name: site.name,
      runtime: 'python',
      entry: _catVodEntryName,
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      entrySha256: hash,
    );
    await File(manifestPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
      flush: true,
    );
    return registry.register(manifestPath);
  }

  Future<List<int>?> _download(Uri uri) async {
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log?.warning(
          '直连站源下载失败 HTTP ${response.statusCode} url=${redactUrl(uri.toString())}',
          scope: 'spider',
        );
        return null;
      }
      if (response.bodyBytes.length > maxBytes) {
        log?.warning(
          '直连站源超过上限 ${response.bodyBytes.length}>$maxBytes url=${redactUrl(uri.toString())}',
          scope: 'spider',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (error) {
      log?.warning(
        '直连站源下载异常 url=${redactUrl(uri.toString())} $error',
        scope: 'spider',
      );
      return null;
    }
  }
}

enum DirectSpiderKind { js, py, catVod }

/// CatVod 壳入口文件名（下载的原始蜘蛛是 loader.py，这个是生成的适配入口）。
const String _catVodEntryName = 'spider.py';

/// 生成的 CatVod 壳入口：把下载来的 loader.py 包成宿主 `create_spider` 契约。
///
/// `root` 取本文件所在目录，避免依赖 sidecar 的工作目录。
const String _catVodEntry = '''
"""由 WebHTV PC 自动生成，请勿手改（重新导入站点时会覆盖）。"""

from pathlib import Path

from webhtv_catvod import create_catvod_spider


def create_spider(manifest=None):
    return create_catvod_spider(
        manifest,
        entry="loader.py",
        root=str(Path(__file__).resolve().parent),
    )
''';

/// 从 `ext` 里取 CatVod 壳地址（`ext.loader`）。
///
/// 安卓生态里这类站点的 `api` 只是壳名（如 `csp_PyProxy`），真正的 Python
/// 蜘蛛地址在 `ext.loader`。`ext` 可能是对象，也可能是 JSON 字符串，还可能
/// 是 Base64 过的 JSON——三种都认。取不到、或不是 http(s) 时返回 null。
String? catVodLoaderUrl(Site site) {
  final ext = site.ext;
  if (ext == null) return null;
  Object? decoded = ext;
  if (ext is String) {
    final text = ext.trim();
    if (text.isEmpty) return null;
    decoded = _tryJson(text) ?? _tryJson(_tryBase64(text) ?? '');
  }
  if (decoded is! Map) return null;
  final loader = decoded['loader'];
  if (loader is! String) return null;
  final url = loader.trim();
  if (url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return url;
}

Object? _tryJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

String? _tryBase64(String text) {
  try {
    return utf8.decode(base64.decode(text));
  } catch (_) {
    return null;
  }
}

/// 判定站点形态；非受支持形态返回 null。
///
/// 顺序即优先级：显式 `.js`/`.py` 后缀 > CatVod 壳（`ext.loader`）。
DirectSpiderKind? directSpiderKind(Site site) {
  if (site.type != 3) return null;
  final api = site.api.trim().toLowerCase();
  if (api.isEmpty) return null;
  if (api.endsWith('.js') || api.contains('.js?')) return DirectSpiderKind.js;
  if (api.endsWith('.py') || api.contains('.py?')) return DirectSpiderKind.py;
  if (catVodLoaderUrl(site) != null) return DirectSpiderKind.catVod;
  return null;
}
