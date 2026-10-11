import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

void main() {
  test('播放器画面模式映射到真实 Video fit/aspectRatio', () {
    expect(PlayerVideoFitMode.contain.fit, BoxFit.contain);
    expect(PlayerVideoFitMode.contain.aspectRatio, isNull);
    expect(PlayerVideoFitMode.cover.fit, BoxFit.cover);
    expect(PlayerVideoFitMode.fill.fit, BoxFit.fill);
    expect(PlayerVideoFitMode.ratio16x9.fit, BoxFit.contain);
    expect(PlayerVideoFitMode.ratio16x9.aspectRatio, closeTo(16 / 9, 0.001));
    expect(PlayerVideoFitMode.ratio4x3.aspectRatio, closeTo(4 / 3, 0.001));
  });

  test('播放器画面模式提供可直接用于设置菜单的中文名称', () {
    expect(
      PlayerVideoFitMode.values.map((mode) => mode.label),
      ['原始比例', '裁切铺满', '拉伸填充', '固定 16:9', '固定 4:3'],
    );
  });
}
