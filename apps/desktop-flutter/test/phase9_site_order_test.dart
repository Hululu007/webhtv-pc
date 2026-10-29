import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/site_order.dart';

void main() {
  group('P1-3 站点健康排序（design/00 §5）', () {
    test('关闭时保持原顺序', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['c', 'a', 'b'],
          enabled: false,
          scores: {'a': 1},
        ),
        ['c', 'a', 'b'],
      );
    });

    test('开启时按成功率降序，无样本排最后', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['no-sample', 'low', 'high'],
          enabled: true,
          scores: {'low': 0.4, 'high': 0.95},
        ),
        ['high', 'low', 'no-sample'],
      );
    });

    test('同分保持原顺序（稳定）', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['b', 'a', 'c'],
          enabled: true,
          scores: {'a': 0.8, 'b': 0.8, 'c': 0.8},
        ),
        ['b', 'a', 'c'],
      );
    });

    test('少于两个站点时原样返回', () {
      expect(
        orderSiteKeysByHealth(keys: ['only'], enabled: true, scores: {}),
        ['only'],
      );
    });
  });

  group('站点排序设置序列化', () {
    test('默认关闭，宽松解析', () {
      expect(const SiteOrderSettings.defaults().healthSort, isFalse);
      expect(SiteOrderSettings.fromJson(null).healthSort, isFalse);
      expect(
        SiteOrderSettings.fromJson({'healthSort': 'yes'}).healthSort,
        isFalse,
      );
      expect(
        SiteOrderSettings.fromJson({'healthSort': true}).healthSort,
        isTrue,
      );
    });

    test('toJson 往返', () {
      const settings = SiteOrderSettings(healthSort: true);
      expect(
        SiteOrderSettings.fromJson(settings.toJson()).healthSort,
        isTrue,
      );
    });
  });
}
