/// 控制浮层（`docs/phase8/design/01` §4）。
///
/// **它不参与布局。** 调用方必须把它作为 `Stack` 的 `Positioned.fill` 子项，
/// 与画面层平级。任何把它放进 `Column`/`Row` 的写法都会让画面重新缩放
/// ——那正是本轮要修的根因（`design/01` §2）。
///
/// 组件根是 `Stack` 且**只含 `Positioned` 子项**：这种情况下 `RenderStack`
/// 取 `constraints.biggest`，于是浮层的大小完全由调用方给的约束决定，
/// 与它内部三段内容的高矮无关。换成 `Column`/`Wrap`/`Align` 都会让
/// 「浮层占多少」重新变成内容的函数。
///
/// 顶栏由调用方传入（`player_page.dart` 传 `AppBar`），因为
/// `integration_test/ui_redesign_visual_flow_test.dart:677-681` 用
/// `find.descendant(of: find.byType(AppBar), ...)` 断言「更多」按钮的位置，
/// **必须保留 `AppBar` widget 类型**（`design/01` §4.1）。
library;

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import 'tokens.dart';

/// 顶栏纱的高度。
///
/// 56（`AppBar` 高度）+ 64 的过渡带：纱到 120 处正好淡到全透明，
/// 画面从顶栏下沿开始重新露出来。写成常量而不是跟着 `topBar` 量，
/// 是因为量尺寸意味着浮层要读子项的固有高度——那正是要避免的耦合。
const double _topScrimExtent = 120;

/// 底栏纱的高度。
///
/// 底栏内容 92（32 进度行 + 4 缝 + 40 动作行 + 上下各 8 内边距）压在
/// 0.86 的最浓处，再往上 68 的过渡带：滑杆两侧的文字必须落在足够深的纱上。
const double _bottomScrimExtent = 160;

/// 浮层的渐变纱。
///
/// 用固定深色而不是 `Theme.of(context).colorScheme.surface`：
/// 播放器背景是**视频帧**，不是应用底色。主题给的 surface 在亮色主题下是浅色，
/// 浅色纱压在高饱和画面上会让文字对比度崩掉
/// （改造前 `player_page.dart` 的注释已经记录了这个问题，实测约 3.5:1）。
///
/// 播放器页整体走恒定暗色主题（`design/01` §4.3），
/// 所以这里的固定深色与页面主题是一致的。
class PlayerOverlayScrim extends StatelessWidget {
  const PlayerOverlayScrim({
    super.key,
    required this.alignment,
    required this.opacity,
  });

  /// 纱最浓的一侧：顶栏用 [Alignment.topCenter]，底栏用 [Alignment.bottomCenter]。
  final Alignment alignment;

  /// 最浓处的不透明度。
  ///
  /// 顶栏 0.72、底栏 0.86（`design/01` §4.3）。底栏更高，因为它承载
  /// 文字与滑杆；顶栏更低，因为从画面到纱的过渡要软，硬边会像贴了一条黑带。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final fromTop = alignment == Alignment.topCenter;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          // 最浓的一侧是 [alignment]，另一端淡到全透明。
          begin: alignment,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            AppPalette.nightGround.withValues(alpha: opacity),
            AppPalette.nightGround.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// 分组之间的发丝竖线。
///
/// 不是按钮，不可配置、不可隐藏——它由分组边界自动插入
/// （`design/03` §5.1）。用户能隐藏的是按钮，不是分组本身。
class PlayerOverlayDivider extends StatelessWidget {
  const PlayerOverlayDivider({super.key});

  /// 发丝线的粗细与长度。
  static const double _thickness = 1;
  static const double _height = 20;

  @override
  Widget build(BuildContext context) {
    // 颜色取 `colorScheme.outline` 而**不是** `Theme.of(context).dividerColor`。
    //
    // 两者在本仓里是不同角色：`dividerColor` 被成 `outlineVariant.withValues(alpha: 0.72)`
    // = `#232C46 @ 0.72`，那是「深色表面上再压一层更深的线」——在应用卡片里没问题，
    // 但这根线画在**视频**上：底栏纱到分隔线所在高度（约 y=552，纱从 440 开始渐变）
    // 只剩约 0.2 的不透明度，画面透出 80%。影片常见的黑边/暗场在这条位置接近纯黑，
    // 深色线压上去实测对比度约 1.2:1 ——**等于没画**。
    //
    // `outline`（暗色下 `#3A4560`）是调色板里「深色底上提亮一档」的那个角色，
    // 压在 `nightGround` 上约 1.9:1：仍是一条发丝线，但在暗场里读得出来。
    // 与亮场也兼容（浅色的线在亮画面上同样可见），所以两种画面都成立。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Container(
        width: _thickness,
        height: _height,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 动作行：单行 + 溢出横向滚动（`design/03` §5.4）。
///
/// 为什么不用 `Wrap`（改造前的写法）：`Wrap` 在窄窗口下换行，浮层高度随之
/// 从 1 行变 2 行，遮住画面的范围不可预测。上游同做法：
/// `view_control_vod_action.xml:2-9` 的 `HorizontalScrollView`。
class PlayerOverlayActionRow extends StatelessWidget {
  const PlayerOverlayActionRow({
    super.key,
    required this.buttons,
    required this.groups,
  });

  final List<Widget> buttons;

  /// 与 [buttons] 一一对应；相邻两项分组不同时插入分隔线。
  final List<PlayerButtonGroup> groups;

  @override
  Widget build(BuildContext context) {
    assert(
      buttons.length == groups.length,
      'actionButtons 与 actionGroups 必须一一对应（${buttons.length} != ${groups.length}）',
    );
    final children = <Widget>[];
    // 逐个下标取分组，且以 `buttons` 为长度基准：release 下断言不生效，
    // 这里也不能越界崩掉播放器（分隔线少画一条好过整页白屏）。
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0 && i < groups.length && groups[i] != groups[i - 1]) {
        children.add(const PlayerOverlayDivider());
      }
      children.add(buttons[i]);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // 不需要显式关滚动条：`MaterialScrollBehavior.buildScrollbar` 对
      // `Axis.horizontal` 直接返回 child（只有纵向才包 `Scrollbar`），
      // 这正好等于上游 `view_control_vod_action.xml:9` 的 `scrollbars="none"`。
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }
}

/// 控制浮层：顶栏 + 进度行 + 动作行。
///
/// 三段都贴边，中间留空给画面——**中间是真的空的**：没有铺满的容器，
/// 所以画面上的单击/双击手势能穿过浮层中部打到下层（`design/01` §7 A3 的前提）。
class PlayerControlOverlay extends StatelessWidget {
  const PlayerControlOverlay({
    super.key,
    required this.topBar,
    required this.progressRow,
    required this.actionButtons,
    required this.actionGroups,
  });

  /// 顶栏。调用方传入 `AppBar`，类型必须保留（见本文件头注释）。
  final Widget topBar;

  /// 进度行（时间 + 滑杆 + 时长）。
  final Widget progressRow;

  final List<Widget> actionButtons;

  /// 与 [actionButtons] 一一对应，用于在分组边界插分隔线。
  final List<PlayerButtonGroup> actionGroups;

  @override
  Widget build(BuildContext context) {
    return Stack(
      // 顶栏、纱、滚动中的动作行都不该画到浮层框外。`Clip.hardEdge` 是
      // `Stack` 的默认值，这里显式写出来：它不是可选装饰，而是行为约定。
      clipBehavior: Clip.hardEdge,
      children: [
        // 顶栏纱：从顶部渐隐。纯装饰，不接收指针。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: _topScrimExtent,
              child: const PlayerOverlayScrim(
                alignment: Alignment.topCenter,
                opacity: 0.72,
              ),
            ),
          ),
        ),
        // 底栏纱：从底部渐隐。底栏承载文字与滑杆，需要更高对比度。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: _bottomScrimExtent,
              child: const PlayerOverlayScrim(
                alignment: Alignment.bottomCenter,
                opacity: 0.86,
              ),
            ),
          ),
        ),
        // 顶栏。放在两条纱之后 = 画在纱之上。
        Positioned(top: 0, left: 0, right: 0, child: topBar),
        // 底栏：进度行 + 动作行，贴着底边往上排。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // **必须 stretch**：`Column` 的默认 `crossAxisAlignment` 是
              // `center`，那样两个孩子都只拿到松散宽度——进度行（一个
              // `SizedBox(height: 32)` 之类的空盒子）会缩成 0 宽并被水平居中，
              // 动作行也会在有富余宽度时**居中**而不是从左边排起
              // （实测：3 个 48 宽按钮的分隔线落在 x=419.5 而不是 108）。
              // `design/03` §5.4 要求「进度行是独立的 Row，始终占满宽度」。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                progressRow,
                const SizedBox(height: AppSpace.xs),
                PlayerOverlayActionRow(
                  buttons: actionButtons,
                  groups: actionGroups,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
