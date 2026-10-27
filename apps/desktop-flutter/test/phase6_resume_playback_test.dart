/// 进度迁移接进播放链路（用户 2026-10-27 要求：跨源续播要"进度完美同步"）。
///
/// 分两层：
/// - **纯逻辑**：`locateResumeEpisode` / `resumeEpisodeMatches` /
///   `resolveResumeStart` 的判定，无 Flutter 依赖；
/// - **映射**：`resumeSeedOf` 把一条 `PlaybackHistory` 抄成 `ResumeSeed`，
///   抄错的后果是"静默丢进度"，只能靠断言锁住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/history_resume_seed.dart';

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

  /// 原记录：线路「线路一」、第 2 集、3 分钟处、该集总长 40 分钟。
  const seedOfEp2 = ResumeSeed(
    flag: '线路一',
    episodeId: 'http://x/e2',
    episodeName: '第2集',
    positionMs: 180000,
    durationMs: 2400000,
  );

  final twoLines = [
    lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
    lineOf('线路二', [('第1集', 'http://y/e1'), ('第2集', 'http://y/e2')]),
  ];

  group('locateResumeEpisode', () {
    test('线路 flag 命中时取那一集', () {
      final located = locateResumeEpisode(lines: twoLines, seed: seedOfEp2);
      expect(located, isNotNull);
      expect(located!.line.flag, '线路一');
      expect(located.episodeIndex, 1);
      expect(located.episodeName, '第2集');
    });

    test('线路 flag 不同但集入口全库唯一命中时也能定位', () {
      final lines = [
        lineOf('线路甲', [('第1集', 'http://a/e1')]),
        lineOf('线路乙', [('第2集', 'http://b/e2')]),
      ];
      const seed = ResumeSeed(
        flag: '已消失的线路',
        episodeId: 'http://b/e2',
        episodeName: '第2集',
        positionMs: 60000,
        durationMs: 100000,
      );
      final located = locateResumeEpisode(lines: lines, seed: seed);
      expect(located?.line.flag, '线路乙');
      expect(located?.episodeIndex, 0);
    });

    test('集入口在多条线路里都能命中（不唯一）时返回 null，不猜', () {
      final lines = [
        lineOf('线路甲', [('第1集', 'http://dup/e1')]),
        lineOf('线路乙', [('第1集', 'http://dup/e1')]),
      ];
      const seed = ResumeSeed(
        flag: '已消失的线路',
        episodeId: 'http://dup/e1',
        episodeName: '第1集',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(locateResumeEpisode(lines: lines, seed: seed), isNull);
    });

    test('空线路列表返回 null', () {
      expect(
        locateResumeEpisode(lines: const [], seed: seedOfEp2),
        isNull,
      );
    });
  });

  group('resumeEpisodeMatches', () {
    test('同一线路同一集 → true', () {
      expect(
        resumeEpisodeMatches(
          lines: twoLines,
          seed: seedOfEp2,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
        ),
        isTrue,
      );
    });

    test('换站后集名带站点前后缀，集号相同即算同一集', () {
      // 原记录：线路一 · 第2集 · http://x/e2。
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
        // 目标站点的集名是站点自己的写法，URL 也不同——唯一相同的只有集号 2。
        lineOf('线路九', [('E02 高清', 'http://z/e2')]),
      ];
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seedOfEp2,
          targetLine: lines[1],
          targetEpisodeIndex: 0,
          targetEpisodeName: 'E02 高清',
        ),
        isTrue,
      );
    });

    test('集号不同 → false（不迁移）', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
        lineOf('线路九', [('第3集', 'http://z/e3')]),
      ];
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seedOfEp2,
          targetLine: lines[1],
          targetEpisodeIndex: 0,
          targetEpisodeName: '第3集',
        ),
        isFalse,
      );
    });

    test('原记录定位不到且集号解析不出来 → false（不迁移）', () {
      final lines = [
        lineOf('别的线路', [('正片', 'http://o/e1')]),
      ];
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://gone/e2',
        episodeName: '特辑',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seed,
          targetLine: lines[0],
          targetEpisodeIndex: 0,
          targetEpisodeName: '花絮',
        ),
        isFalse,
      );
    });

    test('两边都只有一集（电影）→ true', () {
      final single = [lineOf('线路一', [('正片', 'http://x/movie')])];
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/movie',
        episodeName: '正片',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(
        resumeEpisodeMatches(
          lines: single,
          seed: seed,
          targetLine: single[0],
          targetEpisodeIndex: 0,
          targetEpisodeName: '正片',
        ),
        isTrue,
      );
    });
  });

  group('resolveResumeStart', () {
    test('同源 fallback 命中时原样返回（行为与改造前一致）', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 0,
        fallback: const Duration(milliseconds: 12345),
      );
      expect(result, const Duration(milliseconds: 12345));
    });

    test('跨源同一集 → 迁移出原记录的毫秒位置', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 0,
      );
      expect(result, const Duration(milliseconds: 180000));
    });

    test('跨源不是同一集 → null（宁可从头播，不可错续播）', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 0,
        targetEpisodeName: '第1集',
        targetDurationMs: 0,
      );
      expect(result, isNull);
    });

    test('没有种子 → null', () {
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: null,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('种子没有位置（positionMs=0）→ null', () {
      const noPosition = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 0,
        durationMs: 2400000,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: noPosition,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('原记录已播完 → null（从头看）', () {
      const completed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 2390000,
        durationMs: 2400000,
        completed: true,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: completed,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('位置贴着片尾 → null', () {
      const nearEnd = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 2399000,
        durationMs: 2400000,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: nearEnd,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });
  });

  group('resumeSeedOf', () {
    test('字段逐个搬运，一个不漏', () {
      const item = PlaybackHistory(
        id: 7,
        siteKey: 'csp_a',
        vodId: 'v1',
        vodName: '剧名',
        vodPic: 'http://p',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 180000,
        durationMs: 2400000,
        updatedAt: 1,
        completed: true,
        sourceKey: 'bridge|uuid|key',
      );
      final seed = resumeSeedOf(item);
      expect(seed.flag, '线路一');
      expect(seed.episodeId, 'http://x/e2');
      expect(seed.episodeName, '第2集');
      expect(seed.positionMs, 180000);
      expect(seed.durationMs, 2400000);
      expect(seed.completed, isTrue);
    });
  });
}
