import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-state');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
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

  test('未 bootstrap 之外的默认值正确', () {
    expect(state.osdFlags, defaultOsdFlags());
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：未 bootstrap 时（`_uiPreferences == null`）getter 必须回落到默认值，
  // **不得抛异常**。
  //
  // 为什么必须有这一条：上面那个用例的 setUp 总是 `await state.bootstrap()`，
  // 所以 `?? default*` 三条回落分支是**死代码**——变异测试实测确认：
  // 把回落改成 `_uiPreferences!.osdFlags`（会抛）或改成 `const {}`（值错）
  // 都能通过全部 5 个用例。而 `PRODUCT.md` 的失败必须如实原则要求
  // 「取个颜色/取个默认值」这类操作不能把页面打崩。
  test('未 bootstrap 时 getter 回落默认值而不抛异常', () {
    final bare = AppState(paths: state.paths, log: LogService());
    addTearDown(bare.dispose);
    // 不调用 bootstrap()。
    expect(bare.osdFlags, defaultOsdFlags());
    expect(bare.playerButtonOrder, defaultButtonOrder());
    expect(bare.playerButtonHidden, isEmpty);
  });

  // 关键用例：写操作必须真的通知监听者。
  //
  // 为什么必须有这一条：Task 9/10/11 都依赖「用户点了开关 → 界面立刻更新」。
  // 变异测试实测确认：删掉 `setOsdFlag` 里的 `notifyListeners()`，
  // 原有用例（名字里写着「并通知」）**仍然全绿**——它只断言了值，没断言通知。
  test('四个写操作各自通知一次监听者', () async {
    var notifications = 0;
    void listener() => notifications++;
    state.addListener(listener);
    addTearDown(() => state.removeListener(listener));

    await state.setOsdFlag(OsdFlag.mini, true);
    expect(notifications, 1, reason: 'setOsdFlag 必须通知');

    await state.setPlayerButtonOrder(['next', 'play']);
    expect(notifications, 2, reason: 'setPlayerButtonOrder 必须通知');

    await state.setPlayerButtonHidden({'speed'});
    expect(notifications, 3, reason: 'setPlayerButtonHidden 必须通知');

    await state.resetPlayerButtons();
    expect(notifications, 4, reason: 'resetPlayerButtons 必须通知');
  });

  test('设置屏显开关后立即生效并通知', () async {
    await state.setOsdFlag(OsdFlag.mini, true);
    expect(state.osdFlags[OsdFlag.mini], isTrue);
  });

  test('设置按钮顺序后立即生效', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    expect(state.playerButtonOrder.take(2).toList(), ['next', 'play']);
    expect(state.playerButtonOrder.length, 9);
  });

  test('设置隐藏集后立即生效', () async {
    await state.setPlayerButtonHidden({'speed'});
    expect(state.playerButtonHidden, {'speed'});
  });

  test('恢复默认后回到默认顺序与空隐藏集', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    await state.setPlayerButtonHidden({'speed'});
    await state.resetPlayerButtons();
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });
}
