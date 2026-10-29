/// DoH 解析服务（Phase 9 · P2-8）。
///
/// 只作用于**站点/解析/字幕等出站请求**（`AppState` 构造的 HTTP 客户端）；
/// 本地回环播放代理有自己的 DNS 重绑定防护（`proxy_server.dart` 每次连接前
/// `InternetAddress.lookup` + 全地址复核），刻意**不**接 DoH：
/// 否则「解析结果」与「实际连接地址」会脱离它的安全校验链。
///
/// 失败即回落到系统 DNS（并记一次日志），绝不因为 DoH 挂了让站点不可用。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/doh.dart';
import '../core/doh_settings.dart';
import 'log_service.dart';

/// 为某个 DoH 端点构造 HTTP 客户端（可注入假客户端做离线测试）。
typedef DohQueryClientFactory = http.Client Function(DohEndpoint endpoint);

/// 把主机名解析成地址的 DoH 解析器。
class DohResolver {
  DohResolver({
    required this.settings,
    required List<DohEndpoint> endpoints,
    this.hostMap = DohHostMap.empty,
    required this.cachePath,
    this.log,
    this.clientFactory,
    this.queryTimeout = const Duration(seconds: 8),
    this.connectTimeout = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _endpoints = List.unmodifiable(endpoints),
       _now = now ?? DateTime.now;

  final DohSettings settings;
  final DohHostMap hostMap;

  /// DoH 查询客户端工厂（测试注入）。
  final DohQueryClientFactory? clientFactory;

  /// 失败日志（可为 null）。
  final LogService? log;
  final String cachePath;
  final Duration queryTimeout;
  final Duration connectTimeout;
  final DateTime Function() _now;
  final List<DohEndpoint> _endpoints;

  /// 内存缓存：host → (地址, 到期时刻)。
  final Map<String, DohCacheEntry> _cache = {};

  /// 每个端点一个查询客户端（避免每次查询都新建连接池）。
  final Map<String, http.Client> _clients = {};

  /// 失败日志限流：同一主机 60s 只记一次，避免刷满日志。
  final Map<String, DateTime> _lastFailureLog = {};

  bool _cacheLoaded = false;
  Future<void>? _loading;

  /// 生效的端点列表（自定义端点优先）。
  List<DohEndpoint> get effectiveEndpoints {
    if (settings.hasCustomUrl) {
      return [DohEndpoint(url: settings.url.trim())];
    }
    return _endpoints;
  }

  /// DoH 查询是否启用（开关打开且有可用端点）。
  bool get isActive => settings.enabled && effectiveEndpoints.isNotEmpty;

  /// 解析链是否需要接管：静态 hosts 映射独立于 DoH 开关（对齐 catvod
  /// `OkDns.lookup` 先查 hosts 映射、再决定走 DoH 还是系统 DNS）。
  bool get isUsable => hostMap.isNotEmpty || isActive;

  int get cachedHostCount => _cache.length;

  /// 静态映射命中数（用于设置页展示）。
  int get hostMapCount => hostMap.entries.length;

  /// 解析主机名；返回 null 表示「交给系统 DNS」。
  Future<List<InternetAddress>?> resolve(String host) async {
    final target = host.trim();
    if (target.isEmpty) return null;

    final pinned = hostMap.lookup(target);
    if (pinned != null) {
      final address = InternetAddress.tryParse(pinned);
      if (address != null) return [address];
    }
    if (!isActive) return null;

    await _ensureCacheLoaded();
    final cached = _cache[target];
    final nowMs = _now().millisecondsSinceEpoch;
    if (cached != null && !cached.expiredAt(nowMs)) {
      return _toAddresses(cached.addresses);
    }

    final errors = <String>[];
    for (final endpoint in effectiveEndpoints) {
      for (final type in const [DnsRecordType.a, DnsRecordType.aaaa]) {
        final result = await _query(endpoint, target, type);
        if (!result.ok) {
          errors.add('${endpoint.url}: ${result.error}');
          continue;
        }
        final answer = result.answer!;
        final ttl = math.min(
          answer.ttlSeconds,
          settings.cacheMinutes * 60,
        );
        _cache[target] = DohCacheEntry(
          addresses: answer.addresses,
          expiresAtMs: nowMs + ttl * 1000,
        );
        unawaited(_flushCacheQuietly());
        log?.info(
          'DoH 解析 $target -> ${answer.addresses.length} 个地址 '
          'endpoint=${redactDohUrl(endpoint.url)} ttl=${ttl}s',
          scope: 'doh',
        );
        return _toAddresses(answer.addresses);
      }
    }

    _logFailureOnce(target, errors.isEmpty ? '没有可用端点' : errors.join('; '));
    return null;
  }

  /// 作为 `HttpClient.connectionFactory` 使用：先解析，再建连接。
  ///
  /// 走代理时不改写目标（代理自己解析）；直连并且解析成功时连到解析出的 IP，
  /// https 用 `SecureSocket.secure(host: 原域名)` 保证 SNI 与证书校验仍按域名。
  Future<ConnectionTask<Socket>> createConnection(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (proxyHost != null && proxyHost.isNotEmpty) {
      return Socket.startConnect(proxyHost, proxyPort ?? 80);
    }
    final port = uri.port == 0
        ? (uri.isScheme('https') ? 443 : 80)
        : uri.port;
    final addresses = await resolve(uri.host);
    final target = (addresses == null || addresses.isEmpty)
        ? null
        : addresses.first;

    if (uri.isScheme('https')) {
      if (target == null) return SecureSocket.startConnect(uri.host, port);
      final raw = await Socket.connect(target, port, timeout: connectTimeout);
      final secure = await SecureSocket.secure(raw, host: uri.host);
      return ConnectionTask.fromSocket(Future<Socket>.value(secure), () {
        secure.destroy();
      });
    }
    if (target == null) return Socket.startConnect(uri.host, port);
    return Socket.startConnect(target, port);
  }

  /// 清理缓存（域名/设置变化时调用；不删除磁盘文件）。
  void clearCache() => _cache.clear();

  void close() {
    for (final client in _clients.values) {
      try {
        client.close();
      } catch (_) {}
    }
    _clients.clear();
  }

  Future<DohLookupResult> _query(
    DohEndpoint endpoint,
    String host,
    int type,
  ) async {
    final client = _clientFor(endpoint);
    if (client == null) {
      return const DohLookupResult.failure('端点地址不可用');
    }
    final Uri uri;
    try {
      uri = Uri.parse(endpoint.url);
    } catch (_) {
      return const DohLookupResult.failure('端点 URL 非法');
    }
    try {
      final response = await client
          .post(
            uri,
            headers: const {
              'content-type': 'application/dns-message',
              'accept': 'application/dns-message',
            },
            body: buildDnsQuery(
              host: host,
              type: type,
              id: _now().microsecondsSinceEpoch & 0xffff,
            ),
          )
          .timeout(queryTimeout);
      if (response.statusCode != 200) {
        return DohLookupResult.failure('HTTP ${response.statusCode}');
      }
      return parseDnsResponse(response.bodyBytes, host: host);
    } on TimeoutException {
      return const DohLookupResult.failure('超时');
    } catch (error) {
      return DohLookupResult.failure('${error.runtimeType}');
    }
  }

  http.Client? _clientFor(DohEndpoint endpoint) {
    final existing = _clients[endpoint.url];
    if (existing != null) return existing;
    final factory = clientFactory;
    if (factory != null) {
      final client = factory(endpoint);
      _clients[endpoint.url] = client;
      return client;
    }
    if (endpoint.ips.isEmpty) {
      final client = http.Client();
      _clients[endpoint.url] = client;
      return client;
    }
    // bootstrap ips：只在访问该 DoH 服务自身时把域名钉到这些 IP 上。
    final pinned = endpoint.ips
        .map(InternetAddress.tryParse)
        .whereType<InternetAddress>()
        .toList();
    if (pinned.isEmpty) {
      final client = http.Client();
      _clients[endpoint.url] = client;
      return client;
    }
    final host = Uri.parse(endpoint.url).host;
    final inner = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        if (proxyHost != null && proxyHost.isNotEmpty) {
          return Socket.startConnect(proxyHost, proxyPort ?? 80);
        }
        if (uri.host != host) {
          if (uri.isScheme('https')) {
            return SecureSocket.startConnect(uri.host, uri.port);
          }
          return Socket.startConnect(uri.host, uri.port);
        }
        final port = uri.port == 0 ? 443 : uri.port;
        final raw = await Socket.connect(pinned.first, port, timeout: connectTimeout);
        final secure = await SecureSocket.secure(raw, host: host);
        return ConnectionTask.fromSocket(Future<Socket>.value(secure), () {
          secure.destroy();
        });
      };
    final client = IOClient(inner);
    _clients[endpoint.url] = client;
    return client;
  }

  List<InternetAddress> _toAddresses(List<String> values) => [
    for (final value in values)
      if (InternetAddress.tryParse(value) != null)
        InternetAddress.tryParse(value)!,
  ];

  void _logFailureOnce(String host, String detail) {
    final now = _now();
    final last = _lastFailureLog[host];
    if (last != null && now.difference(last).inSeconds < 60) return;
    _lastFailureLog[host] = now;
    if (_lastFailureLog.length > 256) _lastFailureLog.clear();
    log?.warning(
      'DoH 解析失败，回落到系统 DNS：$host（$detail）',
      scope: 'doh',
    );
  }

  Future<void> _ensureCacheLoaded() {
    if (_cacheLoaded) return Future.value();
    return _loading ??= _loadCache();
  }

  Future<void> _loadCache() async {
    try {
      final file = File(cachePath);
      if (await file.exists()) {
        final decoded = DohCacheFile.decode(await file.readAsString());
        final pruned = decoded.pruned(_now().millisecondsSinceEpoch);
        _cache
          ..clear()
          ..addAll(pruned.entries);
      }
    } catch (error) {
      log?.warning('读取 DoH 缓存失败：$error', scope: 'doh');
    }
    _cacheLoaded = true;
  }

  Future<void> _flushCacheQuietly() async {
    try {
      final pruned = DohCacheFile(
        entries: Map.of(_cache),
      ).pruned(_now().millisecondsSinceEpoch);
      _cache
        ..clear()
        ..addAll(pruned.entries);
      final file = File(cachePath);
      await file.parent.create(recursive: true);
      final temp = File('$cachePath.tmp');
      await temp.writeAsString(pruned.encode(), flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(cachePath);
    } catch (error) {
      log?.warning('写入 DoH 缓存失败：$error', scope: 'doh');
    }
  }

  /// 供测试等待挂起的缓存写盘。
  Future<void> flushCache() => _flushCacheQuietly();
}
