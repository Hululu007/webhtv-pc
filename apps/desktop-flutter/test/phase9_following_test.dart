import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

Following _item({
  int released = 0,
  int watched = 0,
  int read = 0,
  int notified = 0,
  String status = FollowingStatus.returning,
}) => Following(
  seriesKey: followingSeriesKey('s', 'v'),
  season: 0,
  siteKey: 's',
  vodId: 'v',
  vodName: '测试剧',
  flag: '线路一',
  sourceFlag: '线路一',
  trackedSeason: 0,
  latestReleasedSeason: 0,
  latestReleasedEpisode: released,
  seasonReleasedEpisodes: released,
  watchedEpisode: watched,
  readWatermarkEpisode: read,
  lastNotifiedEpisode: notified,
  status: status,
  createdAtMs: 1,
  updatedAtMs: 1,
);

void main() {
  group('追番身份与调度（P2-1）', () {
    test('身份键与安卓同格式', () {
      expect(
        followingSeriesKey('SiteA', 'VOD-1'),
        'source:0:sitea:vod-1',
      );
      expect(
        followingIdentityKey('source:0:sitea:vod-1', 2),
        'source:0:sitea:vod-1:s2',
      );
      expect(followingIdentityKey('source:0:a:b', -1), 'source:0:a:b:s0');
    });

    test('调度：连载 6h / 未开播 24h / 完结 7d / 前台 15m', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final returning = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: 0,
      );
      expect(returning - now, const Duration(hours: 6).inMilliseconds);

      final planned = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.planned,
        nextAirAtMs: 0,
      );
      expect(planned - now, const Duration(hours: 24).inMilliseconds);

      final ended = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.ended,
        nextAirAtMs: 0,
      );
      expect(ended - now, const Duration(days: 7).inMilliseconds);

      final foreground = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: 0,
        foreground: true,
      );
      expect(foreground - now, const Duration(minutes: 15).inMilliseconds);
    });

    test('首播时间后 30 分钟追一次；已过期按 1h 后', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final airAt = now + const Duration(minutes: 10).inMilliseconds;
      final fromAir = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: airAt,
      );
      // 首播后 30 分钟与「至少 1 小时后」取较晚者。
      expect(
        fromAir,
        now + FollowingSchedule.minOneShotAfterCheck.inMilliseconds,
      );

      final pastAir = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: now - 1000,
      );
      expect(
        pastAir,
        now + FollowingSchedule.minOneShotAfterCheck.inMilliseconds,
      );
    });

    test('失败退避：15m/30m/1h/2h/6h/1d', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final expected = <int, Duration>{
        1: const Duration(minutes: 15),
        2: const Duration(minutes: 30),
        3: const Duration(hours: 1),
        4: const Duration(hours: 2),
        5: const Duration(hours: 6),
        9: const Duration(days: 1),
      };
      for (final entry in expected.entries) {
        expect(
          FollowingSchedule.backoffAt(now, entry.key) - now,
          entry.value.inMilliseconds,
          reason: 'failure=${entry.key}',
        );
      }
    });
  });

  group('更新/通知策略（P2-1）', () {
    test('首次元数据不制造「新集」提示', () {
      final item = _item();
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 10,
          seasonReleasedEpisodes: 10,
          seasonTotalEpisodes: 12,
          fetchedAtMs: 100,
        ),
        nowMs: 100,
      );
      expect(result.hasNewEpisode, isFalse);
      expect(result.following.readWatermarkEpisode, 10);
      expect(result.following.hasUpdate, isFalse);
    });

    test('已发布超过已看/已读 → 有更新；通知后不再提示', () {
      final item = _item(released: 10, watched: 8, read: 10, notified: 10);
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 12,
          seasonReleasedEpisodes: 12,
          seasonTotalEpisodes: 12,
          fetchedAtMs: 100,
          latestEpisodeName: 'E12',
          latestEpisodeTarget: 'target-12',
        ),
        nowMs: 100,
      );
      expect(result.hasNewEpisode, isTrue);
      final updated = result.following;
      expect(updated.releasedEpisode, 12);
      expect(updated.hasUpdate, isTrue);
      expect(updated.unwatchedCount, 4);
      expect(shouldNotifyFollowing(updated), isTrue);
      expect(updated.latestEpisodeName, 'E12');
      expect(updated.latestEpisodeTarget, 'target-12');

      final notified = markFollowingNotified(updated, nowMs: 200);
      expect(shouldNotifyFollowing(notified), isFalse);

      final read = markFollowingRead(updated, nowMs: 300);
      expect(read.hasUpdate, isFalse);
      expect(read.readWatermarkEpisode, 12);
    });

    test('集数回退不覆盖（max 单调）', () {
      final item = _item(released: 10, read: 10);
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 8,
          seasonReleasedEpisodes: 8,
          seasonTotalEpisodes: 8,
          fetchedAtMs: 100,
        ),
        nowMs: 100,
      );
      expect(result.following.releasedEpisode, 10);
      expect(result.hasNewEpisode, isFalse);
    });

    test('失败写入计数、错误与退避时间', () {
      final failed = markFollowingFailure(
        _item(),
        error: 'HTTP 500',
        nowMs: 1000,
      );
      expect(failed.failureCount, 1);
      expect(failed.lastError, 'HTTP 500');
      expect(
        failed.nextCheckAtMs,
        1000 + const Duration(minutes: 15).inMilliseconds,
      );
    });

    test('设置夹取与 JSON 往返', () {
      final settings = FollowingSettings.defaults.copyWith(
        enabled: true,
        notifyEnabled: true,
        intervalMinutes: 5,
      );
      expect(settings.intervalMinutes, 15);
      expect(FollowingSettings.fromJson(settings.toJson()), settings);
      expect(
        FollowingSettings.fromJson({'intervalMinutes': 99999}).intervalMinutes,
        1440,
      );
    });

    test('Following JSON 往返（备份/同步）', () {
      final item = _item(released: 12, read: 10);
      final parsed = Following.tryParse(item.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.releasedEpisode, 12);
      expect(parsed.hasUpdate, isTrue);
    });
  });

  group('追番存储与服务（P2-1）', () {
    late AppDatabase db;
    late DateTime now;
    late List<FollowingLineEpisodes> lines;
    late Object? failure;
    late FollowingService service;

    setUp(() {
      db = AppDatabase.inMemory();
      now = DateTime(2026, 10, 22, 9);
      lines = const [
        FollowingLineEpisodes(
          flag: '线路一',
          sourceFlag: '线路一',
          episodeCount: 10,
          latestEpisodeName: 'E10',
          latestEpisodeTarget: 't10',
        ),
        FollowingLineEpisodes(
          flag: '线路二',
          sourceFlag: '线路二',
          episodeCount: 4,
        ),
      ];
      failure = null;
      service = FollowingService(
        database: db,
        resolveLines: (item) async {
          if (failure != null) throw StateError('$failure');
          return lines;
        },
        now: () => now,
      );
    });

    tearDown(() => db.dispose());

    test('添加：水位等于已发布，列表可按剧查询', () {
      final item = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      );
      expect(item.readWatermarkEpisode, 10);
      expect(item.hasUpdate, isFalse);
      expect(service.all(), hasLength(1));
      expect(service.byVod('s', 'v')?.vodName, '测试剧');
      expect(service.byKey(item.seriesKey, 0)?.vodId, 'v');
    });

    test('检查：集数增加 → 有新集；按线路匹配而不是第一条', () async {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: '线路二',
        sourceFlag: '线路二',
        releasedEpisode: 4,
      );
      lines = const [
        FollowingLineEpisodes(
          flag: '线路一',
          sourceFlag: '线路一',
          episodeCount: 10,
        ),
        FollowingLineEpisodes(
          flag: '线路二',
          sourceFlag: '线路二',
          episodeCount: 6,
          latestEpisodeName: 'E6',
          latestEpisodeTarget: 't6',
        ),
      ];
      final outcome = await service.check(added);
      expect(outcome.ok, isTrue);
      expect(outcome.changed, isTrue);
      expect(outcome.following.releasedEpisode, 6);
      expect(outcome.following.hasUpdate, isTrue);
      expect(outcome.following.nextCheckAtMs, greaterThan(now.millisecondsSinceEpoch));
      expect(service.byVod('s', 'v')!.releasedEpisode, 6);
    });

    test('检查失败：不抛、写退避与错误', () async {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        releasedEpisode: 1,
      );
      failure = 'HTTP 500';
      final outcome = await service.check(added);
      expect(outcome.ok, isFalse);
      expect(outcome.following.failureCount, 1);
      expect(outcome.following.lastError, contains('HTTP 500'));
      expect(
        outcome.following.nextCheckAtMs,
        now.millisecondsSinceEpoch + const Duration(minutes: 15).inMilliseconds,
      );
    });

    test('checkAll(onlyDue) 只检查到期条目，并发 1', () async {
      final a = service.add(
        siteKey: 's',
        vodId: 'v1',
        vodName: 'A',
        releasedEpisode: 1,
      );
      service.add(
        siteKey: 's',
        vodId: 'v2',
        vodName: 'B',
        releasedEpisode: 1,
      );
      db.upsertFollowing(
        a.copyWith(
          nextCheckAtMs: now.millisecondsSinceEpoch + 100000,
          metadataUpdatedAtMs: 1,
        ),
      );
      final summary = await service.checkAll(onlyDue: true);
      expect(summary.checked, 1, reason: '未到期的 v1 不应检查');
      expect(summary.changed, 1);
      expect(summary.failed, 0);
    });

    test('标记已读/已看会清掉更新标记', () {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        releasedEpisode: 1,
      );
      // `check` 是异步；这里用同步路径直接构造有更新的项。
      final updated = added.copyWith(
        latestReleasedEpisode: 8,
        seasonReleasedEpisodes: 8,
        readWatermarkEpisode: 1,
        watchedEpisode: 1,
      );
      db.upsertFollowing(updated);
      final read = service.markRead(updated);
      expect(read.hasUpdate, isFalse);
      final watched = service.markWatched(read);
      expect(watched.watchedEpisode, 8);
      expect(watched.hasUpdate, isFalse);
    });
  });

  group('追番页（P2-1）', () {
    late Directory temp;
    late AppPaths paths;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-following');
      paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      );
      state = AppState(paths: paths, log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('空态、卡片与更新徽标', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: FollowingPage(state: state)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('following-empty')), findsOneWidget);

      final site = Site(
        key: 's',
        name: '甲站',
        type: 4,
        api: 'http://127.0.0.1:1/vod',
      );
      final item = state.followFromDetail(
        site: site,
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      );
      expect(item, isNotNull);
      // 模拟发现两集新内容。
      state.database!.upsertFollowing(
        item!.copyWith(
          latestReleasedEpisode: 12,
          seasonReleasedEpisodes: 12,
        ),
      );
      state.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const ValueKey('following-list')), findsOneWidget);
      expect(find.text('测试剧'), findsOneWidget);
      expect(find.text('2 新'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('following-update-summary')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('following-check-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('following-auto')), findsOneWidget);
    });
  });
}
