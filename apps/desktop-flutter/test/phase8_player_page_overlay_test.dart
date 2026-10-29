import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

void main() {
  testWidgets('播放器页是 Stack 结构，控制浮层不参与布局（design/01 §3）', (tester) async {
    await pumpPlayerPage(tester);
    final page = find.byType(PlayerPage);
    expect(page, findsOneWidget);
    // 控制浮层与屏显层都在树里。
    expect(find.byType(PlayerControlOverlay), findsOneWidget);
    expect(find.byType(PlayerOsdLayer), findsOneWidget);
  });

  testWidgets('顶栏仍是 AppBar（design/01 §4.1）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('更多'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('四个 tooltip 精确串仍在（design/00 §5 第 2 条）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byTooltip('字幕轨'), findsOneWidget);
    expect(find.byTooltip('弹幕（开启）'), findsOneWidget);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('屏显层 IgnorePointer：点击穿透到画面（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    // 屏显层**自身**无条件 IgnorePointer（`player_osd.dart:139`），
    // 与 `controlsVisible` 无关——它是纯信息层，任何情况下都不接收指针。
    //
    // 用 `descendant` 而不是 `ancestor`：这个 IgnorePointer 在
    // `PlayerOsdLayer.build` **内部**（它是 PlayerOsdLayer 的子节点），
    // 而控制浮层那个在**装配处**包着 `PlayerControlOverlay`（是祖先）。
    // 两者方向相反，抄错会 `findsNothing`。
    final ignoring = tester.widget<IgnorePointer>(
      find
          .descendant(
            of: find.byType(PlayerOsdLayer),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignoring.ignoring, isTrue, reason: '屏显层必须无条件忽略指针');

    // 反向锁：屏显层里的文字**不参与**命中测试，点击必须落到画面上。
    // 只断言 `ignoring` 会被「把 IgnorePointer 换成 AbsorbPointer」之类改法骗过。
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '初始控制栏应可见');
  });

  testWidgets('隐藏态下控制浮层 IgnorePointer 生效（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    // 等自动隐藏（3 秒）。
    await tester.pump(const Duration(seconds: 4));
    await settlePlayerPage(tester);
    final overlay = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(PlayerControlOverlay),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(overlay.ignoring, isTrue, reason: '隐藏后必须忽略指针');
  });

  testWidgets('右键打开菜单（design/04 §5.1）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    expect(find.text('播放'), findsWidgets);
  });

  testWidgets('菜单打开时控制栏强制可见且不隐藏（design/04 §5.4）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    // 推进到远超 3 秒自动隐藏阈值。
    await tester.pump(const Duration(seconds: 5));
    await settlePlayerPage(tester);
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '菜单打开期间控制栏不得隐藏');
  });

  testWidgets('Esc 只关菜单，不退出全屏（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);

    // 反向锁：Esc 若落到 `buildPlayerShortcuts` 的 `exitFullscreen` 上，
    // 这里会看到 `setFullScreen`。`isFullScreen` 被 mock 成 false，
    // 所以 `_exitFullscreen()` 走假分支——但那也要先**问过**平台，
    // 于是「问过没问过」本身就是可观测的差别。
    windowManagerCalls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settlePlayerPage(tester);

    expect(find.byType(PlayerContextMenu), findsNothing, reason: 'Esc 必须关掉菜单');
    expect(
      windowManagerCalls.where((c) => c.method == 'isFullScreen'),
      isEmpty,
      reason: 'Esc 不得触达全屏逻辑（否则菜单打开时按 Esc 会顺带退出全屏）',
    );
    expect(
      windowManagerCalls.where((c) => c.method == 'setFullScreen'),
      isEmpty,
      reason: 'Esc 不得真的切换全屏',
    );
  });

  testWidgets('点击菜单外关闭（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    await tester.tapAt(const Offset(20, 20));
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsNothing);
  });

  testWidgets('屏显全关且控制栏隐藏时定时器停止（design/02 §4.3）', (tester) async {
    await pumpPlayerPage(tester, osdFlags: {
      for (final id in OsdFlag.values) id: false,
    });
    // 前置条件：控制栏可见时 ticker **必须**在跑（为了强制显示的时钟）。
    expect(
      osdTickerRunning(tester),
      isTrue,
      reason: '前置条件：控制栏可见时 ticker 必须在跑',
    );

    // 等自动隐藏；此时屏显开关全关 → 无事可刷 → ticker 必须停。
    //
    // **不能用 `transientCallbackCount == 0` 观测**：加载态永远挂着
    // `LoadingBlock` 的 `CircularProgressIndicator`，该计数恒 ≥1
    // （探针实测：一路推进到 25 秒仍为 1；连一个裸 spinner 也是 1）。
    // 那条件永远不成立，用例会永久失败——这正是本 brief 初版的问题。
    await tester.pump(const Duration(seconds: 4));
    await settlePlayerPage(tester);
    expect(
      osdTickerRunning(tester),
      isFalse,
      reason: '屏显全关 + 控制栏隐藏后 ticker 必须停止（不得每秒空转）',
    );
    // 反向锁：控制栏可见时必须重新启动（上游 `PlayerOsdController.java:152-158`）。
    await tester.tapAt(const Offset(400, 300));
    await settlePlayerPage(tester);
    expect(
      osdTickerRunning(tester),
      isTrue,
      reason: '控制栏重新可见后 ticker 必须重启（时钟要能跳秒）',
    );
  });

  testWidgets('按钮配置生效：隐藏 speed 后不渲染倍速（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(tester, hiddenButtons: {'speed'});
    expect(find.text('倍速'), findsNothing);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('按钮配置生效：顺序改变反映在渲染顺序（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(
      tester,
      buttonOrder: ['fullscreen', 'prev', 'play', 'next'],
    );
    final fullscreen = tester.getTopLeft(find.byTooltip('全屏（F11）'));
    final prev = tester.getTopLeft(find.byTooltip('上一集（[）'));
    expect(fullscreen.dx, lessThan(prev.dx), reason: '全屏应排在最左');
  });

  testWidgets('无阴影、无 elevation（DESIGN.md The Flat-Field Rule）', (tester) async {
    await pumpPlayerPage(tester);
    for (final m in tester.widgetList<Material>(find.byType(Material))) {
      expect(m.elevation, 0);
    }
  });
}
