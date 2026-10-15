/// 详情页历史续播的门禁（`docs/phase6/design/02`）。
///
/// 分两层：
/// - **纯逻辑**（Task 1–2）：`resolveHistoryTarget` 的线路三级匹配与
///   `historyPlayLabel` 的文案决策，无 Flutter 依赖；
/// - **widget**（Task 3 起）：`DetailPage` 的历史参数与自动选线路，
///   需要真实 `AppState` 与窗口。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

void main() {
  VodPlayLine lineOf(
    String flag,
    List<(String, String)> episodes, {
    String? sourceFlag,
  }) => VodPlayLine(
    flag: flag,
    sourceFlag: sourceFlag,
    episodes: [
      for (final (name, url) in episodes) VodEpisode(name: name, url: url),
    ],
  );

  /// 调用助手：默认是「没有历史」（三个字段全空）。
  HistoryResumeTarget resolve({
    String flag = '',
    String episodeId = '',
    String episodeName = '',
    required List<VodPlayLine> lines,
  }) => resolveHistoryTarget(
    historyFlag: flag,
    historyEpisodeId: episodeId,
    historyEpisodeName: episodeName,
    lines: lines,
  );

  final twoLines = [
    lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
    lineOf('线路二', [('第1集', 'http://y/e1'), ('第2集', 'http://y/e2')]),
  ];

  group('无历史', () {
    test('返回第一条线路第 0 集，matched=false', () {
      final target = resolve(lines: twoLines);
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });

    test('没有线路时返回空目标，不抛异常', () {
      final target = resolve(lines: const []);
      expect(target.flag, '');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });

  group('第一级：flag 精确命中', () {
    test('flag 与集 URL 都对上 → 命中', () {
      final target = resolve(
        flag: '线路二',
        episodeId: 'http://y/e2',
        lines: twoLines,
      );
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 1);
      expect(target.episodeName, '第2集');
      expect(target.matched, isTrue);
    });

    test('flag 命中但该线路不含这一集 → 降级到第二级', () {
      // 线路二不含 z/e9，但线路一也不含 → 最终退回第一条线路。
      final target = resolve(
        flag: '线路二',
        episodeId: 'http://z/e9',
        lines: twoLines,
      );
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });

    test('playbackFlag（sourceFlag）也能命中', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1')]),
        lineOf('合并线路', [('第1集', 'http://y/e1')], sourceFlag: '原始flag'),
      ];
      final target = resolve(
        flag: '原始flag',
        episodeId: 'http://y/e1',
        lines: lines,
      );
      expect(target.flag, '合并线路', reason: '按 playbackFlag 匹配，返回展示 flag');
      expect(target.matched, isTrue);
    });
  });

  group('第二级：集 URL 唯一命中', () {
    test('flag 不认识但集 URL 唯一 → 命中那条线路', () {
      final target = resolve(
        flag: '已不存在的线路',
        episodeId: 'http://y/e2',
        lines: twoLines,
      );
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 1);
      expect(target.matched, isTrue);
    });

    test('集 URL 在多条线路里都出现 → 歧义，不猜', () {
      final ambiguous = [
        lineOf('线路一', [('第1集', 'http://same/e1')]),
        lineOf('线路二', [('第1集', 'http://same/e1')]),
      ];
      final target = resolve(
        flag: '不存在的线路',
        episodeId: 'http://same/e1',
        lines: ambiguous,
      );
      expect(target.flag, '线路一', reason: '歧义时退回第一条，不猜');
      expect(target.matched, isFalse);
    });
  });

  group('第三级：线路名命中', () {
    test('flag 命中但集对不上 → 线路命中、不算完整命中', () {
      // 历史 episodeId 是空串（旧数据）→ 第一级因"不含该集"失败，
      // 第二级因 URL 为空无法匹配，第三级按 flag 命中。
      final target = resolve(flag: '线路二', lines: twoLines);
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 0, reason: '集匹配不上时取第 0 集');
      expect(target.matched, isFalse, reason: '线路命中但集没命中 → 不算完整命中');
    });
  });

  group('集匹配', () {
    test('URL 优先于集名', () {
      final lines = [
        lineOf('线路一', [('第9集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
      ];
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第9集',
        lines: lines,
      );
      expect(target.episodeIndex, 1, reason: 'URL 精确匹配优先于集名');
    });

    test('URL 匹配不上时退回集名', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
      ];
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://stale/old',
        episodeName: '第2集',
        lines: lines,
      );
      expect(target.episodeIndex, 1, reason: '集名兜底');
      // 集名兜底**也算完整命中**：线路对上了、集也对上了（只是靠名字而非 URL）。
      // 这条断言是 Task 3 的前提——`matched` 决定是否自动切线路
      // （`design/02` §4.1），不锁住它会让「集名兜底」的行为漂移。
      expect(target.matched, isTrue, reason: '集名命中也是完整命中');
      expect(target.episodeName, '第2集');
    });

    test('都不匹配时取第 0 集且 matched=false', () {
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://stale/old',
        episodeName: '第99集',
        lines: twoLines,
      );
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });

  group('firstEpisodeOf', () {
    test('有线路时返回第一条线路第 0 集', () {
      final target = HistoryResumeTarget.firstEpisodeOf(twoLines);
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });

  group('首屏按钮文案（design/02 §3.1）', () {
    const matched = HistoryResumeTarget(
      flag: '线路一',
      episodeIndex: 1,
      episodeName: '第2集',
      matched: true,
    );
    const unmatched = HistoryResumeTarget(
      flag: '线路一',
      episodeIndex: 0,
      episodeName: '第1集',
      matched: false,
    );

    test('完整命中且有续播位置 → 继续播放 · 集名', () {
      expect(
        historyPlayLabel(
          target: matched,
          resumePosition: const Duration(seconds: 30),
        ),
        '继续播放 · 第2集',
      );
    });

    test('完整命中但无续播位置（已看完 / 位置过短）→ 播放第一集', () {
      expect(
        historyPlayLabel(target: matched, resumePosition: null),
        '播放第一集',
        reason: 'resumePositionFor 已把 completed 与位置过短一起处理',
      );
    });

    test('未完整命中 → 播放第一集', () {
      expect(
        historyPlayLabel(
          target: unmatched,
          resumePosition: const Duration(seconds: 30),
        ),
        '播放第一集',
      );
    });

    test('命中但集名为空 → 用兜底文案', () {
      const noName = HistoryResumeTarget(
        flag: '线路一',
        episodeIndex: 1,
        episodeName: '',
        matched: true,
      );
      expect(
        historyPlayLabel(
          target: noName,
          resumePosition: const Duration(seconds: 30),
        ),
        '播放第一集',
        reason: '没有集名就无法表达"继续播放哪一集"',
      );
    });
  });

  group('DetailPage 自动选历史线路（design/02 §4）', () {
    late Directory tempDir;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-detail-resume');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': tempDir.path, 'local': tempDir.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    /// 把线路条滚进视口。
    ///
    /// `DetailPage` 的背景 hero 是**满屏**的（`TmdbDetailHeader` 实测占满整个
    /// 视口，与 `phase3_detail_page_test` 的 `scrollPastHero` 同一成因），正文
    /// 因此从第二屏开始。正文是懒加载 `ListView`，不滚动就不会挂载线路条，
    /// `find.byKey` 会报 `Bad state: No element`。
    Future<void> revealLineSelector(WidgetTester tester) async {
      final selector = find.byKey(const ValueKey('tmdb-line-selector'));
      for (var attempt = 0; attempt < 20; attempt++) {
        if (selector.evaluate().isNotEmpty) return;
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    Future<void> pumpDetail(
      WidgetTester tester, {
      required Vod vod,
      String historyFlag = '',
      String historyEpisodeId = '',
      Vod? foreignDetailVod,
    }) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // 模拟「本页详情已到达」（`design/02` §4 的自动切线路**只在详情到达后**
      // 才允许发生）：`build` 的守卫是 `belongs && lines.isNotEmpty`，而
      // `belongs` 要求 `state.detailResult` 属于本页影片。不注入的话 `belongs`
      // 恒为 false，切线路根本不触发，用例就变成空洞的了。
      //
      // `loadDetail` 在没有站点服务时提前返回（`app_state.dart` 的
      // `service == null || site == null`），所以这份注入不会被页面自身的
      // 详情请求清掉——与 `phase3_detail_page_test` 的做法一致。
      //
      // 传 `foreignDetailVod` 则注入**别的影片**的详情，用来造
      // `belongs == false`（详情未到达 / 残留）——见「不切线路」那个用例。
      state.seedDetailForTest(vod: foreignDetailVod ?? vod);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: vod,
            historyFlag: historyFlag,
            historyEpisodeId: historyEpisodeId,
          ),
        ),
      );
      await tester.pump();
      await revealLineSelector(tester);
    }

    final twoLineVod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一\$\$\$线路二',
      vodPlayUrl:
          '第1集\$http://x/e1#第2集\$http://x/e2'
          '\$\$\$'
          '第1集\$http://y/e1#第2集\$http://y/e2',
    );

    testWidgets('传入 historyFlag 时选中该线路的 chip', (tester) async {
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '线路二',
        historyEpisodeId: 'http://y/e1',
      );

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(chip.selected, isTrue);
      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isFalse);
    });

    testWidgets('历史线路已不存在时退回第一条线路，不报错', (tester) async {
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '已不存在的线路',
        historyEpisodeId: 'http://nowhere/e1',
      );

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('历史线路在但那一集已消失 → 不切线路（design/02 §4.1）', (tester) async {
      // 线路二存在，但 http://stale/gone 不在任何线路上 →
      // §2.1 第 1 级降级、第 2 级因 URL 非空且无命中而止步、第 3 级被前提挡住
      // → matched == false → **不得**把用户切到线路二（切过去也没有那一集）。
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '线路二',
        historyEpisodeId: 'http://stale/gone',
      );

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue, reason: 'matched=false 时保持第一条线路');
      final second = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(second.selected, isFalse);
    });

    testWidgets('旧数据（无集入口）按线路名命中但集未对上 → 不切线路', (tester) async {
      // historyFlag='线路二' 且 historyEpisodeId=''（旧数据，没有集入口）
      // → §2.1 第三级按线路名命中 → flag='线路二' 但 matched=false。
      // 正确实现（target.matched）：**不**切，仍选线路一。
      // 错误实现（target.flag.isNotEmpty）：会切到线路二 → 本用例失败。
      await pumpDetail(tester, vod: twoLineVod, historyFlag: '线路二');

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue, reason: 'matched=false 时保持第一条线路');
      final second = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(second.selected, isFalse);
    });

    testWidgets('不传历史参数时行为不变（第一条线路）', (tester) async {
      await pumpDetail(tester, vod: twoLineVod);
      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue);
    });

    testWidgets('详情未到达（残留的别的影片详情）→ 不切线路', (tester) async {
      // **这是 `belongs` 守卫的唯一钉子。**
      //
      // 为什么必须单独有它：上面 5 个用例全部走 `belongs == true`。
      // 若只删掉守卫的 `belongs &&`（回到 `lines.isNotEmpty`），
      // 那 5 个用例照样全过——本用例才会失败。
      //
      // 关键设计：注入的详情属于**别的影片**，因此 `belongs == false`
      // 但 `vod` 回退到 `widget.vod`、其 `lines` 是**完整**的两条线路。
      // 于是历史能解析出 `matched == true`（线路二 + 集 URL 命中）——
      // 此时**仍然不得**切线路，因为本页详情尚未到达。
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '线路二',
        historyEpisodeId: 'http://y/e1',
        foreignDetailVod: Vod(
          vodId: 'other-999',
          vodName: '另一部剧',
          vodPlayFrom: '线路X',
          vodPlayUrl: '第1集\$http://z/e1',
        ),
      );

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue, reason: '详情未到达时不得切线路');
      final second = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(second.selected, isFalse);
    });
  });

  group('首屏按钮接历史（design/02 §3）', () {
    // 复用上一组的 setUp/tearDown 结构：这里重新声明一套局部状态，
    // 因为 Dart 的 group 不共享 setUp 变量。
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-hero-play');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一',
      vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2',
    );

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: DetailPage(state: appState, vod: vod)),
      );
      await tester.pump();
      // **注入「本页详情已到达」**：否则 `state.detailResult` 为 null
      // （fake-async 区 HTTP 固定失败），`belongs` 恒为 false。
      //
      // 注：hero 按钮**本身**不依赖它（渲染条件只有 `lines.isNotEmpty`，
      // 而 `widget.vod` 自带两集），但本任务断言的是 `design/02` §3 描述的
      // 「详情到达后用历史决定文案」路径——不注入就是在测另一条路。
      // 依据：`loadDetail` 在无站点服务时**提前返回**（`app_state.dart:2116`，
      // 早于 `_detailResult = null`），注入不会被页面自身请求清掉。
      appState.seedDetailForTest(vod: vod);
      await tester.pump();
    }

    // **不要滚过 hero**：hero 按钮在**首屏**（`heroActions` 是 hero 的一部分），
    // `phase3_detail_page_test.dart` 也是先断言 `detail-hero-play` 存在、
    // **再** `scrollPastHero`。滚动反而会让懒加载列表销毁 hero，
    // 使 `findsOneWidget` 失败。

    testWidgets('无历史 → 文案「播放第一集」', (tester) async {
      await pump(tester);
      expect(find.text('播放第一集'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    });

    testWidgets('有历史且有进度 → 文案「继续播放 · <集名>」', (tester) async {
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 30000,
        durationMs: 100000,
      );
      await pump(tester);
      expect(find.text('继续播放 · 第2集'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    });

    testWidgets('已看完 → 回到「播放第一集」', (tester) async {
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 100000,
        durationMs: 100000,
        completed: true,
      );
      await pump(tester);
      expect(find.text('播放第一集'), findsOneWidget);
      expect(find.textContaining('继续播放'), findsNothing);
    });

    testWidgets('点击播历史命中那一集（design/02 §3.2）', (tester) async {
      // **这是「点击目标」的唯一钉子。**
      //
      // 为什么必须单独有它：上面 3 个用例只断言**渲染出来的文案**，没有一个
      // 真的点下去看播了哪一集。实测把 `_play` 的第 3 个实参改回硬编码 `0`
      // （`design/02` §3.2 明令禁止的那个反实现），那 3 个用例**全部照过**——
      // 于是「点击播命中的那一集」这条明确要求当时一个钉子都没有。
      //
      // 怎么观察到「播了哪一集」：本用例没有站点服务，`resolvePlayback` 直接
      // 返回 null（`app_state.dart` 的 `service == null || site == null`），
      // `_play` 因此抛 `playbackUrlMissing`，其 `detail` 是
      // `line=<flag> episode=<集名>`，经 `AppError.userMessage` 渲染成 SnackBar。
      // 于是断言 SnackBar 里的集名即可区分「命中第2集」与「硬编码第1集」。
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 30000,
        durationMs: 100000,
      );
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
      await tester.pump();
      await tester.pump();

      expect(
        find.textContaining('episode=第2集'),
        findsOneWidget,
        reason: '必须播历史命中的第2集，而不是硬编码的第 0 集（第1集）',
      );
    });
  });

  group('线路 chip 的「最近播放」标记（design/02 §5）', () {
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-line-recent');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      // **`$$$` 必须转义**：`$` 在 Dart 字符串里是插值前缀，
      // 写成 `'线路一$$$线路二'` 会编译失败
      // （`A '$' has special meaning inside a string`）。
      vodPlayFrom: '线路一\$\$\$线路二',
      vodPlayUrl: '第1集\$http://x/e1\$\$\$第1集\$http://y/e1',
    );

    /// 装页面、注入详情、滚到线路条。
    ///
    /// **三件事缺一不可**（Task 3–4 的教训）：
    /// 1. `seedDetailForTest` —— 否则 `detailResult` 为 null、`belongs` 恒为 false，
    ///    走的不是 `design/02` §4 描述的「详情到达后」路径；
    /// 2. 放大视口 —— 800×600 下线路条会被挤出可见区；
    /// 3. **滚过满屏 hero** —— 线路条在正文（第二屏），而正文是懒加载
    ///    `ListView`，不滚过去 `tmdb-line-selector` 根本没挂载，
    ///    `tester.widget<ChoiceChip>` 会抛 `Bad state: No element`。
    Future<void> pumpLineStrip(
      WidgetTester tester, {
      String historyFlag = '线路二',
      String historyEpisodeId = 'http://y/e1',
    }) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: appState,
            vod: vod,
            historyFlag: historyFlag,
            historyEpisodeId: historyEpisodeId,
          ),
        ),
      );
      await tester.pump();
      appState.seedDetailForTest(vod: vod);
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find
            .byKey(const ValueKey('tmdb-line-selector'))
            .evaluate()
            .isNotEmpty) {
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    testWidgets('历史线路的 chip 上有标记，其他线路没有', (tester) async {
      await pumpLineStrip(tester);

      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路一')),
        findsNothing,
      );
    });

    testWidgets('标记不改变 chip 仍可点击切换', (tester) async {
      await pumpLineStrip(tester);

      await tester.tap(find.byKey(const ValueKey('tmdb-line-线路一')));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(chip.selected, isTrue, reason: '用户手动切走必须生效');
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsOneWidget,
        reason: '切走后标记仍在，用户能切回来',
      );
    });

    testWidgets('历史线路在但那一集已消失 → 不标（design/02 §4.1 + §5）', (tester) async {
      // **这是 `matched` 守卫的唯一钉子。**
      //
      // 为什么必须单独有它：上面 2 个用例都走 `matched == true`（线路二 +
      // 集 URL 命中）。实测把 `recentFlag` 的守卫从
      // `matched ? flag : ''` 改成无条件 `flag`，那 2 个用例**全部照过**——
      // 于是「只标历史真正命中的那条线路」这条要求当时一个钉子都没有。
      //
      // 关键设计：线路二存在，但 `http://stale/gone` 不在任何线路上 →
      // §2.1 第 1 级降级、第 2 级因 URL 非空且无命中而止步、第 3 级被前提挡住
      // → `matched == false`、但 `target.flag` 仍回落到**线路一**。此时
      // **不得**标记：标出来会把用户引到一条没有那一集的线路上。
      await pumpLineStrip(tester, historyEpisodeId: 'http://stale/gone');

      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路一')),
        findsNothing,
        reason: 'matched=false 时不得标记',
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsNothing,
        reason: 'matched=false 时不得标记',
      );
    });
  });

  group('选集卡片的「最近播放」标记（design/02 §6）', () {
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-episode-recent');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一',
      vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2#第3集\$http://x/e3',
    );

    /// 两条线路，供「历史命中另一条线路」的钉子用。
    final vodTwoLines = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一\$\$\$线路二',
      vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2#第3集\$http://x/e3'
          '\$\$\$第1集\$http://y/e1#第2集\$http://y/e2#第3集\$http://y/e3',
    );

    Future<void> pump(
      WidgetTester tester, {
      Vod? source,
      String historyFlag = '线路一',
      String historyEpisodeId = 'http://x/e2',
    }) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: appState,
            vod: source ?? vod,
            historyFlag: historyFlag,
            historyEpisodeId: historyEpisodeId,
          ),
        ),
      );
      await tester.pump();
      // **必须注入「本页详情已到达」**：否则 `state.detailResult` 为 null、
      // `belongs` 恒为 false，走的不是 `design/02` §4 描述的路径
      // （与 Task 4/5 同一要求）。
      appState.seedDetailForTest(vod: source ?? vod);
      await tester.pump();
      // **滚过 hero，直到选集区挂载**。
      //
      // 用「找不到就继续拖」的循环而**不是**一次 `drag(-3000)`：
      // hero 是满屏的、正文是懒加载 `ListView`，一次固定位移的拖动在
      // 视口或 hero 高度变化时会拖不够（或拖过头），循环则与具体尺寸无关。
      // Task 3/5 用的是同一个模式。
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find
            .byKey(const ValueKey('tmdb-episode-card-线路一-0'))
            .evaluate()
            .isNotEmpty) {
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    testWidgets('命中的集卡片有标记，其他集没有', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-1')),
        findsOneWidget,
        reason: '第2集（下标 1）被标记',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-0')),
        findsNothing,
      );
    });

    testWidgets('外壳仍是 OutlinedButton（不补集门禁）', (tester) async {
      await pump(tester);
      final buttons = find.byWidgetPredicate(
        (widget) =>
            widget is OutlinedButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'tmdb-episode-card-线路一-',
            ),
      );
      expect(
        buttons,
        findsNWidgets(3),
        reason: '3 集就是 3 张卡，不得补集也不得丢集',
      );
    });

    testWidgets('matched=false 时任何集卡片都不标（design/02 §4.1 + §6）', (tester) async {
      // **这是 `matched` 守卫的钉子。**
      //
      // 为什么必须单独有它：上面 2 个用例都走 `matched == true`。实测把
      // `if (!target.matched) return -1;` 删掉，那 2 个用例**全部照过**——
      // 于是「只标历史真正命中的那一集」这条要求当时一个钉子都没有。
      //
      // 关键设计：`http://stale/gone` 一条线路都匹配不上 →
      // §2.1 第 1 级降级、第 2 级因 URL 非空且无命中而止步、第 3 级被前提挡住
      // → `matched == false`，但 `target.flag` / `target.episodeIndex` 会回落到
      // **第一条线路的第 0 集**——与 `rawLine` 完全重合，正是「守卫一旦拿掉就
      // 立刻误标」的那种重合。标出来会把用户引到一条没有那一集的线路上。
      await pump(tester, historyEpisodeId: 'http://stale/gone');

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-0')),
        findsNothing,
        reason: 'matched=false 时不得标记',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-1')),
        findsNothing,
        reason: 'matched=false 时不得标记',
      );
    });

    testWidgets('切到非历史线路后不标（design/02 §6）', (tester) async {
      // **这是「只标历史那条线路」守卫的钉子。**
      //
      // 实测把 `if (rawLine.flag != target.flag) return -1;` 删掉后，
      // 上面 3 个用例全部照过——因为历史命中的线路恰好就是当前渲染的线路。
      //
      // 手动切到线路二后，`_resumeTarget` 给的仍是线路一的下标 1；不校验
      // 线路就会在线路二的第 2 集上打标，而历史根本不在那条线路上。
      await pump(tester, source: vodTwoLines);
      await tester.tap(find.byKey(const ValueKey('tmdb-line-线路二')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路二-recent-1')),
        findsNothing,
        reason: '历史在线路一，线路二的同下标集不得被标记',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路二-recent-0')),
        findsNothing,
      );
    });

    // 第三条断言「剧照仍是 16:9」**不写**：见下方 Ruling。
  });
}
