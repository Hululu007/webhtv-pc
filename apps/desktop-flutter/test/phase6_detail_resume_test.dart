/// 详情页从历史恢复播放的解析（`docs/phase6/design/02` §2）。
///
/// 纯逻辑，无 Flutter 依赖：线路三级匹配与"歧义就不猜"是本轮最容易写错的
/// 语义，必须在无窗口环境下锁死。
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
  });
}
