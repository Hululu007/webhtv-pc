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
}
