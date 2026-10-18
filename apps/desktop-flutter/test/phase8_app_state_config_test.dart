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
