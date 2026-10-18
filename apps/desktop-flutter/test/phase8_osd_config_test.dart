import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';

void main() {
  group('屏显开关默认值（design/02 §5.1）', () {
    test('默认开启 标题/分辨率/时钟/播放进度', () {
      final flags = defaultOsdFlags();
      expect(flags[OsdFlag.title], isTrue);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.time], isTrue);
      expect(flags[OsdFlag.progress], isTrue);
    });

    test('默认关闭 网速/迷你进度条/诊断面板', () {
      final flags = defaultOsdFlags();
      expect(flags[OsdFlag.traffic], isFalse);
      expect(flags[OsdFlag.mini], isFalse);
      expect(flags[OsdFlag.diagnostics], isFalse);
    });

    test('恰好 7 项，id 集合精确', () {
      expect(OsdFlag.values.length, 7);
      expect(defaultOsdFlags().keys.toSet(), OsdFlag.values.toSet());
    });
  });

  group('屏显开关归一化（design/02 §5.2）', () {
    test('未知键被忽略', () {
      final flags = normalizeOsdFlags({'title': false, 'nonsense': true});
      expect(flags.containsKey('nonsense'), isFalse);
      expect(flags[OsdFlag.title], isFalse);
    });

    test('缺失键补默认值', () {
      final flags = normalizeOsdFlags({'title': false});
      expect(flags.length, 7);
      expect(flags[OsdFlag.title], isFalse);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.mini], isFalse);
    });

    test('非法类型回落默认值', () {
      final flags = normalizeOsdFlags({
        'title': 'yes',
        'size': 1,
        'time': null,
      });
      expect(flags[OsdFlag.title], isTrue);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.time], isTrue);
    });

    test('非 Map 输入整体回落默认', () {
      expect(normalizeOsdFlags('garbage'), defaultOsdFlags());
      expect(normalizeOsdFlags(null), defaultOsdFlags());
      expect(normalizeOsdFlags(42), defaultOsdFlags());
    });

    test('全部关闭时 anyOsdEnabled 为 false', () {
      final all = {for (final id in OsdFlag.values) id: false};
      expect(anyOsdEnabled(all), isFalse);
      expect(anyOsdEnabled(defaultOsdFlags()), isTrue);
    });
  });
}
