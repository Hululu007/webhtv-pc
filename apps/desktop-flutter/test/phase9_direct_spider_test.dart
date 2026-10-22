import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/direct_spider_registrar.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory temp;
  late SpiderManifestRegistry registry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase9-direct');
    registry = SpiderManifestRegistry(root: temp.path, log: LogService());
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Site site(String api, {String key = 'direct-a', int type = 3}) => Site(
    key: key,
    name: '直连 $key',
    type: type,
    api: api,
  );

  group('P1-7 形态判定（README §4.2）', () {
    test('只认 type=3 且 .js/.py', () {
      expect(directSpiderKind(site('https://x.test/a.js')), DirectSpiderKind.js);
      expect(
        directSpiderKind(site('https://x.test/a.py?v=1')),
        DirectSpiderKind.py,
      );
      expect(directSpiderKind(site('https://x.test/api')), isNull);
      expect(
        directSpiderKind(site('https://x.test/a.js', type: 1)),
        isNull,
      );
      expect(directSpiderKind(site('spider-local:a')), isNull);
    });
  });

  group('P1-7 自动注册（README §4.2）', () {
    test('下载 js → 生成 manifest → 注册成功', () async {
      var downloads = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        log: LogService(),
        client: MockClient((request) async {
          downloads += 1;
          return http.Response('module.exports = {};', 200);
        }),
      );

      final config = AppConfig(
        sites: [site('https://x.test/a.js')],
      );
      final result = await registrar.materialize(config);
      expect(result.keys, ['direct-a']);
      expect(downloads, 1);

      final local = result['direct-a']!;
      expect(local.manifest.runtime, 'node');
      expect(local.manifest.entry, 'spider.js');
      expect(local.entryExists, isTrue);
      expect(File(local.manifestPath).existsSync(), isTrue);

      final stored = jsonDecode(File(local.manifestPath).readAsStringSync());
      expect(stored['key'], 'direct-a');
      expect((stored['hashes'] as Map)['entrySha256'], isNotEmpty);
    });

    test('py 站点用 python 运行时', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('pass', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(sites: [site('https://x.test/a.py', key: 'py-a')]),
      );
      expect(result['py-a']!.manifest.runtime, 'python');
      expect(result['py-a']!.manifest.entry, 'spider.py');
    });

    test('哈希一致时不重复下载', () async {
      var downloads = 0;
      DirectSpiderRegistrar build() => DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async {
          downloads += 1;
          return http.Response('same body', 200);
        }),
      );
      final config = AppConfig(sites: [site('https://x.test/a.js')]);
      await build().materialize(config);
      await build().materialize(config);
      expect(downloads, 1, reason: '第二次应命中已有文件与 manifest 哈希');
    });

    test('非 2xx / 超限 / 异常都跳过，不影响其他站点', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        maxBytes: 4,
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('bad.js')) return http.Response('x', 404);
          if (path.endsWith('huge.js')) return http.Response('0123456789', 200);
          if (path.endsWith('boom.js')) throw const SocketException('x');
          return http.Response('ok', 200);
        }),
      );
      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site('https://x.test/bad.js', key: 'bad'),
            site('https://x.test/huge.js', key: 'huge'),
            site('https://x.test/boom.js', key: 'boom'),
            site('https://x.test/good.js', key: 'good'),
          ],
        ),
      );
      expect(result.keys, ['good']);
    });

    test('非 http(s) 的直连形态不注册', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('ok', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(sites: [site(r'C:\spiders\a.js')]),
      );
      expect(result, isEmpty);
    });
  });
}
