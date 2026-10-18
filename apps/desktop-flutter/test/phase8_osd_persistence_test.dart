import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-prefs');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  group('屏显持久化（design/02 §5.2）', () {
    test('从未设置过时返回默认表，且不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.osdFlags, defaultOsdFlags());
      expect(store.hasExplicitOsd, isFalse);
      await store.rememberSite('muou');
      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('osd'), isFalse, reason: '缺席 = 默认，不得固化进文件');
    });

    test('写入后重新 load 得到同一张表', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.mini, true);
      await store.rememberOsdFlag(OsdFlag.title, false);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.osdFlags[OsdFlag.mini], isTrue);
      expect(reloaded.osdFlags[OsdFlag.title], isFalse);
      expect(reloaded.osdFlags[OsdFlag.size], isTrue, reason: '未设置的项用默认');
      expect(reloaded.hasExplicitOsd, isTrue);
    });

    test('非法 id 被忽略，不写坏状态', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag('nonsense', true);
      expect(store.osdFlags.containsKey('nonsense'), isFalse);
    });

    test('只改 ui 段：sync 段保留', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'sync': {'token': 'keep-me'},
          'tmdb': {'enabled': true},
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.diagnostics, true);

      final raw = readRaw();
      expect((raw['sync'] as Map)['token'], 'keep-me');
      expect((raw['tmdb'] as Map)['enabled'], isTrue);
    });
  });

  group('按钮配置持久化（design/03 §4.2）', () {
    test('从未设置过时返回默认顺序与空隐藏集', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder, defaultButtonOrder());
      expect(store.buttonHidden, isEmpty);
      expect(store.hasExplicitPlayerButtons, isFalse);
    });

    test('写入顺序与隐藏集后重新 load 得到同一结果', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play', 'prev']);
      await store.rememberButtonHidden({'speed', 'line'});

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder.take(3).toList(), ['next', 'play', 'prev']);
      expect(reloaded.buttonOrder.length, 9, reason: '缺失项补全到末尾');
      expect(reloaded.buttonHidden, {'speed', 'line'});
      expect(reloaded.hasExplicitPlayerButtons, isTrue);
    });

    test('恢复默认清除两个键', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play']);
      await store.rememberButtonHidden({'speed'});
      await store.resetPlayerButtons();

      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('playerButtons'), isFalse);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder, defaultButtonOrder());
      expect(reloaded.buttonHidden, isEmpty);
    });

    test('兼容逗号分隔字符串（上游格式）', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {
            'playerButtons': {'order': 'next,play', 'hidden': 'speed'},
          },
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder.take(2).toList(), ['next', 'play']);
      expect(store.buttonHidden, {'speed'});
    });
  });
}
