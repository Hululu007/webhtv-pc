/// AI 集季识别端到端（`docs/phase6/design/05` §4.4 D19）。
///
/// **真实窗口 + 真实 HTTP + 真实 SQLite**：
/// - AI 请求打到本进程内的 `FakeAiServer`（`fixture_ai.dart`）；
/// - TMDB 请求打到既有的本地 fixture 服务
///   （`tools/fixture_server`，基址由 `WEBHTV_FIXTURE_BASE` 指定）。
///
/// **不访问任何外部网络。**
///
/// ## 为什么走真实 UI 路径（而不是状态层测试口子）
///
/// `_openSeasonDialog` 里有一段**必须在 `bindTmdbSeason` 之前**的分流
/// （`design/04` §7.1.1）：`TmdbSeasonAi` / `TmdbSeasonAiSettings` 的
/// `bindingModeOf` 返回 `null`，与 `TmdbSeasonAuto` 同义（＝清除手动绑定）。
/// 直接调状态层会绕过这段分流，于是「点‘去配置 AI’把用户已有绑定清掉」
/// 这个最危险的失效模式在 L3 完全没有覆盖——而那正是设计点名的
/// 「本轮最容易写错的一处」。所以这里一律**点按钮**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'fixture_ai.dart';

void evidence(String message) =>
    debugPrint('PHASE6-AI-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 既有本地 fixture 服务（`design/05` §3）。TMDB 路由与观测数据都在里面。
  final fixtureBase =
      Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

  late FakeAiServer fake;
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    fake = await FakeAiServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-ai-season-flow');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();

    // 站点：既有的 `tmdb-detail` fixture 站点，线路一 = S1 12 + S2 10 = 22 集，
    // 线路二 = S2 8 集（`tools/fixture_server/server.py`）。
    final imported = await state.importConfig(
      jsonEncode({
        'name': 'AI 集季 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$fixtureBase/api/tmdb-detail',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    // TMDB → 本地 fixture 服务（`apiBase` 可配，全量 `tmdb_*` L3 都这么做）。
    // `imageBase`/`backdropBase` 显式给出：fixture 的 `/configuration` 路由
    // 不在 `/3/` 命名空间下（服务端只认 route `/configuration`），
    // 依赖它去推导图片基址会得到 404——既有的 `tmdb_detail_flow_test` 也正是
    // 因此把两个图片基址写死。
    final savedTmdb = await state.saveTmdbConfig(
      state.tmdbConfig.copyWith(
        apiBase: '$fixtureBase/tmdb/3',
        apiKey: 'fixture-key',
        accessToken: '',
        imageBase: '$fixtureBase/tmdb-img/w342',
        backdropBase: '$fixtureBase/tmdb-img/w780',
        enabledSites: const [],
        disabledSites: const [],
        allowedSites: const [],
      ),
    );
    expect(savedTmdb, isTrue, reason: 'TMDB 设置写入失败');

    // AI → 本进程内的假服务端（`openai_chat` → POST `/v1/chat/completions`）。
    final savedAi = await state.saveAiConfig(
      AiConfig(
        enabled: true,
        protocol: AiProtocol.openAiChat,
        endpoint: '${fake.baseUrl}/v1',
        apiKey: 'sk-test',
        model: 'fake-model',
      ),
    );
    expect(savedAi, isTrue, reason: 'AI 设置写入失败');
    expect(state.aiReady, isTrue, reason: 'AI 必须就绪，否则 AI 项会走「去配置」');
  });

  tearDown(() async {
    state.dispose();
    await fake.stop();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 在真实 async 区推进 I/O，直到 [until] 成立或超时。
  Future<void> drainReal(
    WidgetTester tester, {
    required bool Function() until,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (until()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// 打开详情页并等 TMDB 匹配 + 季度解析完成。
  Future<void> pumpMatchedDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final vod = Vod(vodId: 'tmdb-demo', vodName: '示例剧集');
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pump();

    await drainReal(tester, until: () => state.detailPhase == LoadPhase.ready);
    await drainReal(
      tester,
      until: () => state.tmdb.hasMatch && state.tmdb.detail != null,
    );
    await drainReal(
      tester,
      until: () => state.tmdb.seasonEpisodeCounts.isNotEmpty,
    );
    expect(state.tmdb.hasMatch, isTrue, reason: 'TMDB 未匹配');
    expect(
      state.tmdb.seasonEpisodeCounts.isNotEmpty,
      isTrue,
      reason: 'AI 分析的输入（季集数）必须就绪',
    );
    evidence(
      'matched=${state.tmdb.item?.title} counts=${state.tmdb.seasonEpisodeCounts} '
      'line=${state.tmdb.sourceLine?.flagKey} '
      'episodes=${state.tmdb.sourceLine?.episodeCount} '
      'selected=${state.tmdb.selectedSeason} canAutoSlice=${state.tmdb.canAutoSlice}',
    );
  }

  /// 只打开季度弹窗（不点任何项）。
  ///
  /// 必须先滚过满屏 hero：季度按钮在第二屏，不滚过去它根本没挂载
  /// （`DetailPage` 正文是懒构建 `ListView`）。
  Future<void> openSeasonDialog(WidgetTester tester) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (find
          .byKey(const ValueKey('tmdb-season-button'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('tmdb-season-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tmdb-season-dialog')),
      findsOneWidget,
      reason: '季度弹窗未打开',
    );
  }

  /// 打开季度弹窗并点「AI 识别剧集/季度」。
  Future<void> tapAiSeasonItem(WidgetTester tester) async {
    await openSeasonDialog(tester);
    await tester.tap(find.byKey(const ValueKey('tmdb-season-ai')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('D19：分析 → 预览 → 应用（KEEP_ORIGINAL 落盘）', (tester) async {
    // 让假服务端慢一点：进度框必须能被观察到，否则等于没验证
    // 「分析期间有取消入口」这条承诺。
    fake.delay = const Duration(milliseconds: 400);
    fake.usePreset(FakeAiPreset.keepOriginal);
    await pumpMatchedDetail(tester);
    // 线路一默认选中第 1 季（多季），应用 `KEEP_ORIGINAL` 后应变成「未指定」。
    expect(state.tmdb.selectedSeason, 1, reason: '前置：默认选中第 1 季');

    await tapAiSeasonItem(tester);
    expect(
      find.byKey(const ValueKey('ai-season-progress')),
      findsOneWidget,
      reason: '分析期间必须有进度框与取消按钮',
    );
    expect(find.byKey(const ValueKey('ai-season-cancel')), findsOneWidget);

    await drainReal(
      tester,
      until: () =>
          find.byKey(const ValueKey('ai-season-preview')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('ai-season-preview')),
      findsOneWidget,
      reason: '分析成功必须进入预览确认（绝不自动落盘）',
    );
    expect(
      find.text('保持原始集列表 · 70%'),
      findsOneWidget,
      reason: '预览必须写明 mode 与置信度',
    );

    // **确认之前不得落盘**（P2：AI 必经确认）。
    expect(
      state.tmdb.selectedSeason,
      1,
      reason: '预览阶段绝不能已经改动绑定',
    );

    await tester.tap(find.byKey(const ValueKey('ai-season-apply')));
    await drainReal(tester, until: () => state.tmdb.selectedSeason == -1);
    expect(state.tmdb.selectedSeason, -1, reason: '确认后才落盘 manualFlat');
    evidence(
      'applied=KEEP_ORIGINAL selected=${state.tmdb.selectedSeason} '
      'paths=${fake.requestPaths}',
    );
  });

  testWidgets('EXPLICIT_MAPPING 仅预览：没有「应用建议」', (tester) async {
    fake.usePreset(FakeAiPreset.explicitMapping);
    await pumpMatchedDetail(tester);
    final before = state.tmdb.selectedSeason;

    await tapAiSeasonItem(tester);
    await drainReal(
      tester,
      until: () =>
          find.byKey(const ValueKey('ai-season-preview')).evaluate().isNotEmpty,
    );

    expect(
      find.byKey(const ValueKey('ai-season-preview-only')),
      findsOneWidget,
      reason: '逐集映射必须明说只预览',
    );
    expect(
      find.byKey(const ValueKey('ai-season-apply')),
      findsNothing,
      reason: '逐集映射不提供应用按钮（本版本不落盘）',
    );
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(state.tmdb.selectedSeason, before, reason: '逐集映射不改绑定');
  });

  testWidgets('FLAT_BY_COUNTS：应用前再校验 canAutoSlice（不匹配则拒绝落盘）', (tester) async {
    fake.usePreset(FakeAiPreset.flatByCounts);
    await pumpMatchedDetail(tester);

    // 【为何这条用例锁的是「拒绝」而不是「成功应用」】
    //
    // `design/04` §7.4 要求：`FLAT_BY_COUNTS` 应用前**再校验一次**
    // `canAutoSlice`，“AI 说可以，但本地校验不过 → 报失败，不写绑定”。
    // 而既有 fixture 的 TMDB 含特别篇（S0 3 + S1 12 + S2 10 = 25），
    // 线路一只有 22 集，`canAutoSlice` 为 false，因此这里天然能验证
    // **安全拒绝路径**。
    //
    // 这比“两边都说可以”的顺利路径更值得锁：拒绝路径错了就是静默写坏绑定。
    expect(
      state.tmdb.canAutoSlice,
      isFalse,
      reason: '前置：线路一集数（22）≠ TMDB 总集数（25，含特别篇）',
    );
    final before = state.tmdb.selectedSeason;

    await tapAiSeasonItem(tester);
    await drainReal(
      tester,
      until: () =>
          find.byKey(const ValueKey('ai-season-preview')).evaluate().isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('ai-season-preview')),
      findsOneWidget,
      reason: '解析本身是合法的，应进入预览',
    );

    await tester.tap(find.byKey(const ValueKey('ai-season-apply')));
    await drainReal(
      tester,
      until: () => find.byType(SnackBar).evaluate().isNotEmpty,
    );
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('无法安全自动切分'),
      ),
      findsOneWidget,
      reason: '本地校验不过必须明确报失败',
    );
    expect(
      state.tmdb.selectedSeason,
      before,
      reason: '校验不过时绝不写绑定（04 §7.4）',
    );
    evidence('flat-by-counts refused: canAutoSlice=false, binding=${state.tmdb.selectedSeason}');
  });

  testWidgets('HTTP 失败 → 只提示错误，绑定不变，不进预览', (tester) async {
    fake.failNext = true;
    await pumpMatchedDetail(tester);
    final before = state.tmdb.selectedSeason;

    await tapAiSeasonItem(tester);
    await drainReal(tester, until: () => find.byType(SnackBar).evaluate().isNotEmpty);

    expect(find.byType(SnackBar), findsOneWidget, reason: '失败必须给用户提示');
    expect(
      find.byKey(const ValueKey('ai-season-preview')),
      findsNothing,
      reason: '失败时不得进入预览',
    );
    expect(state.tmdb.selectedSeason, before, reason: '绑定不得改变');
    evidence('http-failure snackbar=${find.byType(SnackBar).evaluate().length}');
  });

  testWidgets('分析失败（硬校验拒绝）→ 提示且不落盘', (tester) async {
    fake.usePreset(FakeAiPreset.invalidSeason);
    await pumpMatchedDetail(tester);
    final before = state.tmdb.selectedSeason;

    await tapAiSeasonItem(tester);
    await drainReal(tester, until: () => find.byType(SnackBar).evaluate().isNotEmpty);

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-season-preview')), findsNothing);
    expect(state.tmdb.selectedSeason, before, reason: '硬校验失败不得落盘');
  });

  testWidgets('取消分析 → 绑定不变，不进预览', (tester) async {
    // 让响应慢下来，否则进度框可能在点击之前就消失了。
    fake.delay = const Duration(seconds: 2);
    fake.usePreset(FakeAiPreset.singleSeason);
    await pumpMatchedDetail(tester);
    final before = state.tmdb.selectedSeason;

    await tapAiSeasonItem(tester);
    expect(find.byKey(const ValueKey('ai-season-progress')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-season-cancel')));
    await tester.pumpAndSettle();

    // 等那笔在途请求真的收尾，避免留下悬挂的 Future。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('ai-season-preview')),
      findsNothing,
      reason: '取消后不得进入预览',
    );
    expect(state.tmdb.selectedSeason, before, reason: '取消不改绑定');
    // 取消是即时短路：用户点取消的那一刻就不该再等结果。
    expect(
      find.byType(DetailPage),
      findsOneWidget,
      reason: '点「取消」不能把详情页一起弹掉',
    );
  });

  testWidgets('D12：未配置 AI → 弹窗引导，去设置且不误清绑定', (tester) async {
    await state.saveAiConfig(const AiConfig());
    expect(state.aiReady, isFalse);
    await pumpMatchedDetail(tester);
    final before = state.tmdb.selectedSeason;

    // 先只开弹窗：AI 项**必须在**，且带「去设置」引导（不隐藏——隐藏会让
    // 用户永远不知道有 AI 能力）。
    await openSeasonDialog(tester);
    expect(
      find.byKey(const ValueKey('tmdb-season-ai')),
      findsOneWidget,
      reason: '未配置时 AI 项仍须可见',
    );
    expect(
      find.textContaining('未配置 AI 服务'),
      findsOneWidget,
      reason: '未配置时要引导去设置',
    );

    // 点它 → 进设置页，且**不得**被当成「清除手动绑定」。
    await tester.tap(find.byKey(const ValueKey('tmdb-season-ai')));
    await tester.pumpAndSettle();

    expect(
      find.byType(AiSettingsPage),
      findsOneWidget,
      reason: '未配置时应打开 AI 设置页',
    );
    expect(
      state.tmdb.selectedSeason,
      before,
      reason: '「去配置 AI」绝不能被解释成「清除手动绑定」（design/04 §7.1.1）',
    );
    evidence('ai-settings-page opened, binding=${state.tmdb.selectedSeason}');
  });
}
