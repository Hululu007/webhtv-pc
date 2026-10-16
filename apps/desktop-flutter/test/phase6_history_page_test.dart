/// 历史页与设置页的交互门禁（`docs/phase6/design/01` §4.3、§7）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
    bool inShell = false,
    double textScaleFactor = 1.0,
  }) async {
    if (textScaleFactor != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // `inShell: true` 复刻真实壳层：左栏 76 + `VerticalDivider(width: 1)`，
    // 于是**内容区宽 ≠ 整窗宽**。这正是判据：
    // 列数必须来自 `LayoutBuilder` 的 `constraints.maxWidth`（内容区），
    // 而不是 `MediaQuery.sizeOf(context).width`（整窗）。
    final page = HistoryPage(state: state);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: inShell
              ? Row(
                  children: [
                    const SizedBox(width: 76),
                    const VerticalDivider(width: 1),
                    Expanded(child: page),
                  ],
                )
              : page,
        ),
      ),
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

    // 列数的**基准宽度**必须是内容区，而不是整窗（`design/01` §2.2 要求与首页
    // 海报墙共用同一套算法，而首页用的是 `LayoutBuilder(constraints.maxWidth)`）。
    // 壳层左侧有 `NavigationRail`(76) + `VerticalDivider`(1)，两者相差 77px。
    // 窗宽 1100 时两种口径必然分叉：
    //   整窗（错）：usable 1100-32 = 1068，1068/164 = 6.51 → 7 列
    //   内容（对）：usable 1100-77-32 = 991，991/164 = 6.04 → 6 列
    testWidgets('列数按内容区宽度算，不是整窗宽（壳层下列数不偏多）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester, size: const Size(1100, 1000), inShell: true);
      expect(
        _historyColumns(tester),
        6,
        reason:
            '壳层里内容区只有 1023px：列数必须用 LayoutBuilder 的 constraints.maxWidth。'
            '用 MediaQuery.sizeOf 会算成 7 列（比首页海报墙多一列）。',
      );
    });

    // 无障碍放大字号时，卡片**不得溢出格子**。`_historyCaptionHeight` 是固定值
    // （DESIGN.md 的「文字区高 40px」，与首页共用），所以文字区必须夹住放大倍数
    // ——首页 `_VodCard` 就是这么做的（`browse_pages.dart` 的
    // `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.25)`）。
    //
    // 取 1.5 而不是 1.25：1.25 是**clamp 的上界本身**，在 1.25 下「夹住」与
    // 「没夹住」观察结果相同，测不出 clamp 是否真的存在。
    for (final scale in const [1.5, 2.0]) {
      testWidgets('文字放大 $scale 倍时卡片不溢出', (tester) async {
        seedHistory(id: 1, vodName: '剧集甲');
        await pumpHistory(
          tester,
          size: const Size(1400, 1000),
          textScaleFactor: scale,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'textScaleFactor=$scale 时卡片溢出了固定高度的文字区',
        );
        // 片名仍然只渲染一次（放大不能靠复制一份「缩小版」文字来兜底）。
        expect(find.text('剧集甲'), findsOneWidget);
      });
    }
  });

  group('删除态（design/01 §3）', () {
    testWidgets('长按卡片进入删除态：出现遮罩与「完成」', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();

      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('history-delete-overlay-1')),
        findsOneWidget,
      );
    });

    testWidgets('删除态下点卡片即删该条，仍在删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsNothing, reason: '该条被删除');
      expect(find.text('剧集乙'), findsOneWidget, reason: '另一条不受影响');
      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsOneWidget,
        reason: '还有条目时仍在删除态',
      );
      expect(state.recentHistory().length, 1, reason: '必须真的落盘');
    });

    testWidgets('删除态删掉最后一条后自动退出', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('暂无播放记录'), findsOneWidget);
    });

    testWidgets('点「完成」退出删除态且不删任何东西', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
      expect(state.recentHistory().length, 1);
    });

    testWidgets('再次长按退出删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      // 先断言**真的进去了**：否则「退出」断言在「从未进入」时也绿（假绿）。
      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
    });

    testWidgets('空历史时不渲染删除入口', (tester) async {
      await pumpHistory(tester);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsNothing);
    });

    // **`design/01` §3.2 这一段自相矛盾**（同一场景两个相反结论）：
    //   句2「搜索出 1 条、删掉它之后，可见列表为空 → 退出删除态」
    //   句3「搜索后可见 1 条，删掉这 1 条**不应**退出（还有 9 条被搜索词挡着）」
    //   句5「判定必须用 `_items`（过滤后）而不是 `state.recentHistory()`（全量）」
    // 句3 与句5 **不可兼得**：用 `_items` 判定 ⇒ 删掉可见最后一条后必然为空
    // ⇒ 必然退出（= 句2），永远达不到句3。
    //
    // **裁定：退出**。依据 3 条 vs 1 条：
    //   ① `design/05` A11d（**验收判据**）只写了退出条款：
    //      「删除态删掉"过滤后最后一条"才退出」；
    //   ② §3.2 句5 是实现指令，用 `_items` 必然导出退出；
    //   ③ §3.2 句2 是**加粗的主规则**（「判定基准是过滤后的可见列表」）；
    //   ④ 上游 `HistoryActivity` 无搜索，`getItemCount() == 0 → setDelete(false)`
    //      （其 `getItemCount()` 等价于全量，但全量==可见时与句2 一致）。
    // UX 判据（决定性）：若「不退出」，可见列表已空、删除态横幅仍在，屏幕会同时
    // 出现「暂无播放记录」与「点击卡片即删除该条记录」——自相矛盾的界面，
    // 正是 design 自己批判的反模式（「点了什么也没有的按钮比没有按钮更糟」）。
    //
    // 这条用例同时是**判定基准**的钉子：若实现改用 `state.recentHistory()`（全量）
    // 判空，则全量还有 1 条 → 不退出 → 本用例失败。
    testWidgets('删掉过滤后最后一条即退出（裁定：§3.2 句3 与句5 冲突，取句5）', (
      tester,
    ) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.enterText(find.byType(TextField), '剧集乙');
      await tester.pump();
      expect(find.text('剧集甲'), findsNothing, reason: '前置：搜索已把它挡住');

      await tester.longPress(find.byKey(const ValueKey('history-row-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-2')));
      await tester.pumpAndSettle();

      expect(
        state.recentHistory().length,
        1,
        reason: '全量里还有「剧集甲」（被搜索词挡着）',
      );
      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsNothing,
        reason:
            '判定必须用 `_items`（过滤后）：可见列表已空 → 退出。'
            '用 `state.recentHistory()`（全量）判空会留在这个已无卡片可点的模式里。',
      );
    });

    // Esc 退出（`design/01` §3.1 的「退出方式」列）。
    testWidgets('Esc 退出删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget, reason: 'Esc 不删任何东西');
    });

    // 删除态下**必须**逐条走 `state.deleteHistory`（而不是直接改本地列表）：
    // 它同时写 `history_deletions` 标记，否则安卓下次推来旧记录会复活
    // （`docs/phase5/design/02` §4.5）。
    testWidgets('删除会写删除标记（否则远端旧记录会复活）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(
        state.database!.historyDeletionCount,
        1,
        reason: '删除必须留下 history_deletions 标记（phase5 design/02 §4.5）',
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
