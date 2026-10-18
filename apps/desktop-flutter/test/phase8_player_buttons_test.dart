import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';

void main() {
  group('按钮定义（design/03 §3.2、§5.3）', () {
    test('恰好 9 项，id 集合精确', () {
      expect(kPlayerButtons.length, 9);
      expect(
        kPlayerButtons.map((b) => b.id).toList(),
        ['prev', 'play', 'next', 'mute', 'volume', 'speed', 'line', 'episodes', 'fullscreen'],
      );
    });

    test('顶栏常驻的 subtitle/danmaku 不在可配置集合里', () {
      final ids = kPlayerButtons.map((b) => b.id).toSet();
      expect(ids.contains('subtitle'), isFalse);
      expect(ids.contains('danmaku'), isFalse);
      expect(ids.contains('video_fit'), isFalse);
      expect(ids.contains('media_info'), isFalse);
      expect(ids.contains('diagnostics'), isFalse);
    });

    test('每个 id 唯一，label 非空', () {
      final ids = kPlayerButtons.map((b) => b.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final spec in kPlayerButtons) {
        expect(spec.label.trim().isNotEmpty, isTrue);
      }
    });

    test('默认顺序就是定义顺序', () {
      expect(defaultButtonOrder(), kPlayerButtons.map((b) => b.id).toList());
    });
  });

  group('顺序归一化（design/03 §4.3）', () {
    test('非法 id 被过滤', () {
      final order = normalizeButtonOrder(['play', 'nonsense', 'prev']);
      expect(order.contains('nonsense'), isFalse);
      expect(order.first, 'play');
    });

    test('重复 id 去重', () {
      final order = normalizeButtonOrder(['play', 'play', 'prev']);
      expect(order.where((id) => id == 'play').length, 1);
    });

    test('缺失项追加到末尾（老配置 + 新按钮）', () {
      final order = normalizeButtonOrder(['play', 'prev']);
      expect(order.length, 9);
      expect(order[0], 'play');
      expect(order[1], 'prev');
      // 其余按默认顺序补齐在末尾。
      expect(order.sublist(2), defaultButtonOrder().sublist(2));
    });

    test('接受逗号分隔字符串（兼容上游格式）', () {
      final fromString = normalizeButtonOrder('play,prev,next');
      final fromList = normalizeButtonOrder(['play', 'prev', 'next']);
      expect(fromString, fromList);
    });

    test('空/非法输入回落默认顺序', () {
      expect(normalizeButtonOrder(null), defaultButtonOrder());
      expect(normalizeButtonOrder(''), defaultButtonOrder());
      expect(normalizeButtonOrder(42), defaultButtonOrder());
      expect(normalizeButtonOrder(<String>[]), defaultButtonOrder());
    });
  });

  group('隐藏集归一化（design/03 §4.3）', () {
    test('非法 id 被过滤', () {
      final hidden = normalizeButtonHidden(['media_info', 'play']);
      expect(hidden.contains('media_info'), isFalse);
      expect(hidden.contains('play'), isTrue);
    });

    test('去重', () {
      final hidden = normalizeButtonHidden(['play', 'play']);
      expect(hidden.length, 1);
    });

    test('接受逗号分隔字符串', () {
      expect(normalizeButtonHidden('play,next'), normalizeButtonHidden(['play', 'next']));
    });

    test('空输入得到空集', () {
      expect(normalizeButtonHidden(null), isEmpty);
      expect(normalizeButtonHidden(''), isEmpty);
    });
  });

  group('可见列表解析（design/03 §5.1）', () {
    test('按 order 排序、按 hidden 过滤', () {
      final visible = resolveVisibleButtons(
        order: ['next', 'play', 'prev'],
        hidden: {'play'},
      );
      expect(visible.map((b) => b.id).toList(), ['next', 'prev']);
    });

    test('全部隐藏时返回空列表', () {
      final visible = resolveVisibleButtons(
        order: defaultButtonOrder(),
        hidden: kPlayerButtons.map((b) => b.id).toSet(),
      );
      expect(visible, isEmpty);
    });
  });
}
