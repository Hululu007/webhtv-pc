import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
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

  Site site(
    String api, {
    String key = 'direct-a',
    int type = 3,
    Object? ext,
  }) => Site(key: key, name: '直连 $key', type: type, api: api, ext: ext);

  /// CatVod 壳站点的 ext：真正的蜘蛛地址在 loader 里。
  Map<String, Object?> shellExt(String loader) => {
    'api': 'https://pan.test',
    'loader': loader,
    'secret': 'x',
    'token': '2024',
  };

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

  group('CatVod 壳站点（方案 2）', () {
    test('api 只写壳名时按 ext.loader 认形态', () {
      final shell = site(
        'csp_PyProxy',
        key: 'shell-a',
        ext: shellExt('https://pan.test/Atvp.py?v=1'),
      );
      expect(directSpiderKind(shell), DirectSpiderKind.catVod);
      expect(catVodLoaderUrl(shell), 'https://pan.test/Atvp.py?v=1');

      // ext 是 JSON 字符串、以及 Base64 过的 JSON，都要认。
      final asJson = site(
        'csp_PyProxy',
        key: 'shell-b',
        ext: jsonEncode(shellExt('https://pan.test/a.py')),
      );
      expect(directSpiderKind(asJson), DirectSpiderKind.catVod);
      final asBase64 = site(
        'csp_PyProxy',
        key: 'shell-c',
        ext: base64Encode(
          utf8.encode(jsonEncode(shellExt('https://pan.test/b.py'))),
        ),
      );
      expect(catVodLoaderUrl(asBase64), 'https://pan.test/b.py');

      // 没有 loader、loader 不是 http(s)、或 ext 缺失 → 不认。
      expect(directSpiderKind(site('csp_PyProxy', ext: {'api': 'x'})), isNull);
      expect(
        directSpiderKind(
          site('csp_PyProxy', ext: shellExt(r'C:\spiders\a.py')),
        ),
        isNull,
      );
      expect(directSpiderKind(site('csp_PyProxy')), isNull);

      // 显式 .py/.js 后缀仍优先于壳判定。
      expect(
        directSpiderKind(
          site('https://x.test/a.py', ext: shellExt('https://pan.test/a.py')),
        ),
        DirectSpiderKind.py,
      );
    });

    test('下载 loader → 生成壳入口与 manifest → 注册成功', () async {
      var downloads = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        log: LogService(),
        client: MockClient((request) async {
          downloads += 1;
          expect(request.url.path, endsWith('Atvp.py'));
          return http.Response('class Spider:\n    pass\n', 200);
        }),
      );

      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site(
              'csp_PyProxy',
              key: 'shell-a',
              ext: shellExt('https://pan.test/Atvp.py?v=1'),
            ),
          ],
        ),
      );

      expect(downloads, 1);
      final local = result['shell-a']!;
      expect(local.manifest.runtime, 'python');
      expect(local.manifest.entry, 'spider.py');
      expect(local.entryExists, isTrue);

      final dir = p.dirname(local.manifestPath);
      final entry = File(p.join(dir, 'spider.py')).readAsStringSync();
      expect(entry, contains('create_catvod_spider'));
      expect(entry, contains('create_spider'));
      expect(File(p.join(dir, 'loader.py')).existsSync(), isTrue);

      final stored = jsonDecode(File(local.manifestPath).readAsStringSync());
      expect(stored['key'], 'shell-a');
      expect(stored['runtime'], 'python');
    });

    test('同一 api 的多个壳站点互不覆盖', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('pass', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site(
              'csp_PyProxy',
              key: 'shell-a',
              ext: shellExt('https://pan.test/a.py'),
            ),
            site(
              'csp_PyProxy',
              key: 'shell-b',
              ext: shellExt('https://pan.test/b.py'),
            ),
          ],
        ),
      );
      expect(result.keys, ['shell-a', 'shell-b']);
      expect(
        p.dirname(result['shell-a']!.manifestPath),
        isNot(p.dirname(result['shell-b']!.manifestPath)),
      );
    });

    test('loader 哈希一致时不重复下载', () async {
      var downloads = 0;
      DirectSpiderRegistrar build() => DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async {
          downloads += 1;
          return http.Response('same loader', 200);
        }),
      );
      final config = AppConfig(
        sites: [
          site(
            'csp_PyProxy',
            key: 'shell-a',
            ext: shellExt('https://pan.test/a.py'),
          ),
        ],
      );
      await build().materialize(config);
      await build().materialize(config);
      expect(downloads, 1);
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
