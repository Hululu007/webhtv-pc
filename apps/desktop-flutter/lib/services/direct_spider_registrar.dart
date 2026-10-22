/// 直连 `.js` / `.py` 站点的自动注册（`docs/phase9/README.md` P1-7）。
///
/// 安卓允许站点 `api` 直接指向一个 JS/Python 文件；PC 端此前要求用户手工写
/// `spider-local:` manifest。这里把「下载 → 落盘 → 生成 manifest → 注册」自动化，
/// 复用同一套 `webhtv-ipc-v1` sidecar（不新增运行时）。
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

enum DirectSpiderKind { js, py }

/// 判定站点 `api` 是否是直连 js/py 形态；非 http(s) 返回 null。
DirectSpiderKind? directSpiderKind(Site site) {
  if (site.type != 3) return null;
  final api = site.api.trim().toLowerCase();
  if (api.isEmpty) return null;
  if (api.endsWith('.js') || api.contains('.js?')) return DirectSpiderKind.js;
  if (api.endsWith('.py') || api.contains('.py?')) return DirectSpiderKind.py;
  return null;
}
