/// `csp_*` 配置声明 jar 的自动探测（方案 3、`docs/reference/win-box-borrowings.md` §12.9）。
///
/// 覆盖点：
/// - 桌面 jar（无 dex / 无 .so / 入口类存在）→ 自动装入 `<csp>/<key>/`；
/// - 含 `classes.dex` 的 Android jar → **不落盘**，但结论写进 `probe.json`，
///   站点列表显示程序已试过的真实原因（不再是「请自己放 jar」）；
/// - 同一 URL 被多个站点共用时只下载一次（AT 有 90+ 站点共用 spring.jar）；
/// - 取回失败有冷却期，静态结论永久生效（重下也是同一结论）；
/// - 已导入的站点不被覆盖；
/// - 全程不启动 JVM、不加载类。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';

void main() {
  late Directory tempRoot;
  late LogService log;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('webhtv-csp-probe');
    log = LogService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  Site cspSite(String api, {String? key, String? jar}) => Site(
    key: key ?? api,
    name: api,
    type: 3,
    api: api,
    jar: jar,
    searchable: true,
  );

  AppConfig configOf(List<Site> sites, {String? spider}) => AppConfig(
    name: 'csp 探测测试',
    sites: sites,
    spider: spider,
  );

  /// 计数器：断言「同一 URL 只下一次」。
  late List<String> downloads;

  CspJarProbe probeWith(http.Client client) => CspJarProbe(
    root: p.join(tempRoot.path, 'spiders'),
    binding: CspJvmBinding(root: p.join(tempRoot.path, 'spiders', 'csp')),
    log: log,
    client: client,
  );

  CspJvmBinding binding() =>
      CspJvmBinding(root: p.join(tempRoot.path, 'spiders', 'csp'));

  Future<Uint8List> desktopJar() async {
    final file = File(p.join(tempRoot.path, 'desktop.jar'));
    await _writeZip(file, {
      'Metadata.class': const [0xca, 0xfe, 0xba, 0xbe, 0x01],
      'Demo.class': const [0xca, 0xfe, 0xba, 0xbe, 0x02],
    });
    return file.readAsBytes();
  }

  Future<Uint8List> androidJar() async {
    final file = File(p.join(tempRoot.path, 'android.jar'));
    await _writeZip(file, {
      'classes.dex': const [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35],
      'META-INF/MANIFEST.MF': const [0x4d, 0x61],
    });
    return file.readAsBytes();
  }

  setUp(() => downloads = []);

  test('桌面 jar 自动装入缓存目录，站点转为可用', () async {
    final bytes = await desktopJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([cspSite('csp_Demo', jar: 'https://example.test/jar/demo.jar')]),
    );

    expect(report.installed, 1);
    expect(report.entries.single.outcome, CspProbeOutcome.installed);
    expect(downloads, hasLength(1));

    final entryPath = binding().entryFor('csp_Demo');
    expect(entryPath, isNotNull);
    expect(File(entryPath!).existsSync(), isTrue);
    expect(CspJvmBinding.isAndroidJar(entryPath), isFalse);

    final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
    expect(record, isNotNull);
    expect(record!['installed'], isTrue);
    expect(record['verdict'], JarVerdict.desktopReady.name);
  });

  test('含 classes.dex 的 jar 不落盘，只写结论并回显到站点列表', () async {
    final bytes = await androidJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([
        cspSite('csp_PianDan', jar: 'https://example.test/jar/spring.jar'),
      ]),
    );

    expect(report.rejected, 1);
    expect(report.installed, 0);
    expect(report.entries.single.inspection?.verdict, JarVerdict.androidJar);

    // 纪律：含 dex 的入口永不落盘——目录里只允许有 probe.json 结论，
    // 不得出现 index.jar / classes 这类可被 JVM 加载的入口。
    expect(binding().entryFor('csp_PianDan'), isNull);
    final dir = Directory(binding().directoryFor('csp_PianDan'));
    final names = dir.existsSync()
        ? dir.listSync().map((e) => p.basename(e.path)).toList()
        : <String>[];
    expect(names, ['probe.json']);

    final record = JarIntake.probeRecord(binding().directoryFor('csp_PianDan'));
    expect(record!['verdict'], JarVerdict.androidJar.name);
    expect('${record['summary']}', contains('ADR-0002'));

    final router = SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      cspBinding: binding(),
    );
    final availability = router.classifySite(
      cspSite('csp_PianDan', jar: 'https://example.test/jar/spring.jar'),
    );
    expect(availability.available, isFalse);
    expect(availability.reason, contains('自动检测失败'));
    expect(availability.reason, contains('ADR-0002'));
  });

  test('多个站点共用一个 URL 时只下载一次', () async {
    final bytes = await androidJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );

    final report = await probe.materialize(
      configOf([
        cspSite('csp_A', jar: 'https://example.test/jar/spring.jar'),
        cspSite('csp_B', jar: 'https://example.test/jar/spring.jar'),
        cspSite('csp_C', jar: 'https://example.test/jar/spring.jar'),
      ]),
    );

    expect(report.entries, hasLength(3));
    expect(downloads, hasLength(1));
  });

  test('顶层 spider 字段也算配置声明的 jar', () async {
    final bytes = await desktopJar();
    final probe = probeWith(
      MockClient((request) async => http.Response.bytes(bytes, 200)),
    );

    final report = await probe.materialize(
      configOf([cspSite('csp_Demo')], spider: 'https://example.test/s.jar'),
    );

    expect(report.installed, 1);
  });

  test('取回失败记录失败原因，冷却期内不重复请求', () async {
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('nope', 500);
      }),
    );

    final config = configOf([
      cspSite('csp_Demo', jar: 'https://example.test/dead.jar'),
    ]);
    final first = await probe.materialize(config);
    expect(first.failed, 1);
    expect(first.entries.single.message, contains('取回失败'));

    final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
    expect(record!['verdict'], 'fetchFailed');

    // 第二轮：同一 URL 在冷却期内，不得再打一遍死链。
    final second = await probe.materialize(config);
    expect(second.entries.single.outcome, CspProbeOutcome.rejected);
    expect(downloads, hasLength(1));
  });

  test('静态结论永久生效：已判 androidJar 后不再重下', () async {
    final bytes = await androidJar();
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );
    final config = configOf([
      cspSite('csp_Demo', jar: 'https://example.test/spring.jar'),
    ]);

    await probe.materialize(config);
    await probe.materialize(config);
    expect(downloads, hasLength(1));
  });

  test('已导入的站点跳过探测，不下载也不覆盖', () async {
    final bytes = await desktopJar();
    final targetDir = binding().directoryFor('csp_Demo');
    final staged = File(p.join(tempRoot.path, 'manual.jar'));
    await staged.writeAsBytes(bytes, flush: true);
    final manual = await JarIntake.install(
      sourcePath: staged.path,
      targetDir: targetDir,
      siteKey: 'csp_Demo',
    );
    expect(manual.ok, isTrue);

    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response.bytes(bytes, 200);
      }),
    );
    final report = await probe.materialize(
      configOf([cspSite('csp_Demo', jar: 'https://example.test/demo.jar')]),
    );

    expect(report.entries.single.outcome, CspProbeOutcome.skippedInstalled);
    expect(downloads, isEmpty);
  });

  test('已有自己运行时的站点（CatVod 壳）不参与 JVM 探测', () async {
    // AT 的顶层 spider 指向 spring.jar；壳站点的 api 只是壳名 csp_PyProxy，
    // 没有「声明 jar」的语义，若被 effectiveJar 兜到就会白下一份 spring.jar。
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('x', 200);
      }),
    );
    final report = await probe.materialize(
      configOf([
        Site(
          key: 'py',
          name: 'PyProxy',
          type: 3,
          api: 'csp_PyProxy',
          ext: {'loader': 'https://example.test/Atvp.py?v=1'},
        ),
      ], spider: 'https://example.test/spring.jar'),
    );

    expect(report.isEmpty, isTrue);
    expect(downloads, isEmpty);
  });

  test('配置里没有 csp_ 站点时不做任何事', () async {
    final probe = probeWith(
      MockClient((request) async {
        downloads.add(request.url.toString());
        return http.Response('x', 200);
      }),
    );
    final report = await probe.materialize(
      configOf([
        Site(key: 'http', name: 'http', type: 4, api: 'https://x.test/api'),
      ]),
    );

    expect(report.isEmpty, isTrue);
    expect(downloads, isEmpty);
  });

  group('JarSourceSpec：TVBox 的 ;md5; 后缀', () {
    test('解析 URL 与 md5', () {
      final spec = JarSourceSpec.parse(
        'http://192.168.50.50:3000/custom_spider.jar?token=abc;md5;'
        'cc3b3d2ddf389338b62eccd4a938b610',
      );
      expect(spec, isNotNull);
      expect(spec!.url, 'http://192.168.50.50:3000/custom_spider.jar?token=abc');
      expect(spec.md5, 'cc3b3d2ddf389338b62eccd4a938b610');
    });

    test('非 http(s) 或空值不接受', () {
      expect(JarSourceSpec.parse(null), isNull);
      expect(JarSourceSpec.parse('  '), isNull);
      expect(JarSourceSpec.parse(r'C:\\spiders\\a.jar'), isNull);
    });

    test('md5 不匹配**不再拒绝**：按内容继续判定并装好', () async {
      // 用户原话：「能下载但 md5 不符，这个不校验」。
      // TVBox 生态里服务端重新打包却不更新配置的 md5 极常见，按它拒绝
      // 只会丢掉本来能用的入口；真正判据是 JarIntake 的静态检测。
      final bytes = await desktopJar();
      final probe = probeWith(
        MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      final report = await probe.materialize(
        configOf([
          cspSite(
            'csp_Demo',
            jar: 'https://example.test/demo.jar;md5;'
                '00000000000000000000000000000000',
          ),
        ]),
      );

      expect(report.installed, 1);
      expect(report.rejected, 0);
      expect(binding().entryFor('csp_Demo'), isNotNull);
      final record = JarIntake.probeRecord(binding().directoryFor('csp_Demo'));
      expect(record!['declaredMd5'], '00000000000000000000000000000000');
      expect(record['actualMd5'], isNot('00000000000000000000000000000000'));
      expect(record['verdict'], isNot('checksumMismatch'));
      expect('${record['summary']}', contains('已忽略'));
    });

    test('旧版本写下的 checksumMismatch 结论立即失效并重下', () async {
      final bytes = await desktopJar();
      final downloads = <String>[];
      final probe = probeWith(
        MockClient((request) async {
          downloads.add(request.url.toString());
          return http.Response.bytes(bytes, 200);
        }),
      );
      // 模拟旧版本留下的结论。
      await JarIntake.writeProbe(binding().directoryFor('csp_Demo'), {
        'siteKey': 'csp_Demo',
        'sourceUrl': 'https://example.test/demo.jar',
        'declaredMd5': 'cc3b3d2ddf389338b62eccd4a938b610',
        'fetchedAt': DateTime.now().toIso8601String(),
        'verdict': 'checksumMismatch',
        'summary': '配置声明的 md5 与实际内容不一致',
      });

      final report = await probe.materialize(
        configOf([
          cspSite(
            'csp_Demo',
            jar: 'https://example.test/demo.jar;md5;'
                'cc3b3d2ddf389338b62eccd4a938b610',
          ),
        ]),
      );

      expect(downloads, hasLength(1), reason: '旧结论不得阻止重新取回');
      expect(report.installed, 1);
      expect(binding().entryFor('csp_Demo'), isNotNull);
    });
  });
}

/// 写一个 stored（不压缩）zip：条目名与内容都可控，CRC 正确，可被 archive 解析。
Future<void> _writeZip(File file, Map<String, List<int>> entries) async {
  final builder = BytesBuilder();
  final central = <List<int>>[];
  entries.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final offset = builder.length;
    final crc = getCrc32(data);
    builder.add(_le32(0x04034b50));
    builder.add(_le16(20));
    builder.add(_le16(0));
    builder.add(_le16(0)); // method = stored
    builder.add(_le16(0));
    builder.add(_le16(0));
    builder.add(_le32(crc));
    builder.add(_le32(data.length));
    builder.add(_le32(data.length));
    builder.add(_le16(nameBytes.length));
    builder.add(_le16(0));
    builder.add(nameBytes);
    builder.add(data);
    central.add([
      ..._le32(0x02014b50),
      ..._le16(20),
      ..._le16(20),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(crc),
      ..._le32(data.length),
      ..._le32(data.length),
      ..._le16(nameBytes.length),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(0),
      ..._le32(offset),
      ...nameBytes,
    ]);
  });
  final centralStart = builder.length;
  for (final record in central) {
    builder.add(record);
  }
  final centralSize = builder.length - centralStart;
  builder.add(_le32(0x06054b50));
  builder.add(_le16(0));
  builder.add(_le16(0));
  builder.add(_le16(central.length));
  builder.add(_le16(central.length));
  builder.add(_le32(centralSize));
  builder.add(_le32(centralStart));
  builder.add(_le16(0));
  await file.writeAsBytes(builder.takeBytes());
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];
