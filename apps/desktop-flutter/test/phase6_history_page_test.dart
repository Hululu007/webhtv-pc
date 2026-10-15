/// 历史页与设置页的交互门禁（`docs/phase6/design/01` §4.3、§7）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-page');
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

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
    );
    await tester.pump();
  }

  testWidgets('设置页有「历史记录」区块与两个选项', (tester) async {
    await pumpSettings(tester);
    expect(find.text('历史记录'), findsOneWidget);
    final selector = find.byKey(
      const ValueKey('settings-history-click-action'),
    );
    expect(selector, findsOneWidget);
    expect(find.text('进入详情页'), findsOneWidget);
    expect(find.text('直接播放'), findsOneWidget);
  });

  testWidgets('默认选中「进入详情页」', (tester) async {
    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('settings-history-click-action')),
    );
    expect(button.selected, {UiHistoryClickAction.detail});
  });

  testWidgets('已保存的偏好决定初始选中项（不是永远显示第一项）', (tester) async {
    // 变异自检发现的覆盖缺口：把 `selected` 写死成 `{detail}` 时前三个用例
    // 照样全绿。这里先把偏好改成 `play` 再建页面——选中态必须来自
    // `AppState.historyClickAction`，而不是常量。
    //
    // 真实 I/O 必须放进 `runAsync`：`testWidgets` 是假时钟，写盘回调不会被
    // `pump` 推进（见 `phase5_sync_ui_test.dart` 顶部注释）。
    await tester.runAsync(
      () => state.setHistoryClickAction(UiHistoryClickAction.play),
    );
    expect(state.historyClickAction, UiHistoryClickAction.play);

    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('settings-history-click-action')),
    );
    expect(button.selected, {UiHistoryClickAction.play});
  });

  testWidgets('点「直接播放」写入偏好', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('直接播放'));
    await tester.pumpAndSettle();
    expect(state.historyClickAction, UiHistoryClickAction.play);
  });

  /// 直接往库里塞一条历史，绕过播放器。
  ///
  /// **`vodId` / `episodeId` 必须随 `id` 变化**：`history` 表的唯一键是
  /// `(site_key, vod_id, flag, episode_id)`，全部用同一个默认值时三次
  /// `upsertHistory` 会走 `ON CONFLICT ... DO UPDATE` **塌成同一行**，
  /// 「3 条历史」的用例就只剩最后一条。
  void seedHistory({
    required int id,
    required String vodName,
    String episodeName = '第1集',
    String siteKey = 'site-a',
    String? vodId,
    String flag = '线路一',
    String? episodeId,
    int positionMs = 30000,
    int durationMs = 100000,
    int? updatedAt,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId ?? 'v$id',
      vodName: vodName,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId ?? 'http://x/e$id',
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt,
    );
  }

  Future<void> pumpHistory(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HistoryPage(state: state))),
    );
    await tester.pump();
  }

  group('历史页卡片网格（design/01 §2）', () {
    testWidgets('渲染为网格，卡片数 == 历史条数', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲', updatedAt: 3000);
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 2000);
      seedHistory(id: 3, vodName: '剧集丙', updatedAt: 1000);
      // 前置条件自检：三条种子必须真的是三行（否则「只出现一次」是假绿）。
      expect(state.recentHistory().length, 3);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);
      expect(find.byType(SliverGrid), findsWidgets);
      for (final name in const ['剧集甲', '剧集乙', '剧集丙']) {
        expect(find.text(name), findsOneWidget, reason: '$name 必须出现且只出现一次');
      }
      // 用例标题里的「卡片数 == 历史条数」必须真的被断言：只查片名挡不住
      // 「多渲染了空卡片」这类变异（如 `itemCount` 写大一点）。
      for (final id in const [1, 2, 3]) {
        expect(
          find.byKey(ValueKey('history-row-$id')),
          findsOneWidget,
          reason: '第 $id 条历史必须有且只有一张卡片',
        );
      }
    });

    testWidgets('每张卡片只渲染一次片名 Text', (tester) async {
      seedHistory(id: 1, vodName: '唯一片名');
      await pumpHistory(tester);
      expect(find.text('唯一片名'), findsOneWidget);
    });

    testWidgets('海报保持 2:3', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);
      final box = tester.getSize(
        find
            .descendant(
              of: find.byKey(const ValueKey('history-row-1')),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      expect(box.width / box.height, closeTo(2 / 3, 0.05));
    });

    testWidgets('空历史显示空态，不渲染网格', (tester) async {
      await pumpHistory(tester);
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-grid')), findsNothing);
    });

    // 变异自检发现的覆盖缺口：把 `columns` 写死成常量（例如 `3`）时，上面四条
    // 用例**全部照绿**——它们只看「有没有网格 / 片名出现几次 / 海报比例」，
    // 而写死列数在 1400 宽下同样能给出 2:3 的海报。列数自适应是
    // `design/01` §2.2 明确要求的（「列数按窗口宽自适应」），必须单独钉住。
    testWidgets('列数随窗口宽自适应（不是写死的常量）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      // 期望值来自 DESIGN.md 的「内容网格」实测取值：目标列宽 150、列间距 14、
      // 网格内边距 16 → usable = 宽 - 32，columns = round(usable / 164)。
      // 宽 1400：usable 1368，1368/164 = 8.34 → 8 列。
      // 宽 700： usable  668， 668/164 = 4.07 → 4 列。
      await pumpHistory(tester, size: const Size(1400, 1000));
      expect(
        _historyColumns(tester),
        8,
        reason: '1400 宽必须铺 8 列（DESIGN.md 的目标列宽 150 + 列间距 14）',
      );

      await pumpHistory(tester, size: const Size(700, 1000));
      expect(
        _historyColumns(tester),
        4,
        reason: '700 宽必须收到 4 列——写死列数会让窄窗口下的海报比例失真',
      );
    });
  });
}

/// 读出历史网格当前的实际列数。
int _historyColumns(WidgetTester tester) {
  final grid = tester.widget<GridView>(
    find.byKey(const ValueKey('history-grid')),
  );
  return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
      .crossAxisCount;
}
