/// 播放器右键菜单（`docs/phase8/design/04`）。
///
/// ## 为什么不用 `showMenu` / `MenuAnchor`（进 `Navigator` 的 `Overlay`）
///
/// 本项目的截图 harness（`integration_test/ui_redesign_visual_flow_test.dart:71-99`）
/// 取树中**第一个 `RepaintBoundary`**（`Scaffold` 那层）。`Overlay` 里的浮层
/// **拍不到**——该文件已在两处记录过这个限制（`:584-587` 的筛选面板、
/// `:708-711` 的播放器溢出菜单），并明确写了「不拿重复的图冒充新证据」。
///
/// 因此本菜单实现为**页内 `Stack` 子层**：它在 `Scaffold` 的 `RepaintBoundary`
/// 内，harness 能拍到**真实渲染**的菜单，也能断言它的矩形。
///
/// 代价是要自己实现「点外关闭」与「Esc 关闭」。两者都在 `player_page.dart` 里
/// （`design/04` §5.3：全屏透明遮罩是菜单层的**兄弟**、`Esc` 用内层
/// `CallbackShortcuts` 盖住全局的 `exitFullscreen`），远小于「拿不到视觉证据」的代价。
///
/// ## 坐标空间
///
/// [PlayerContextMenu.anchor] 必须是**父 `Stack` 的坐标**（不是屏幕坐标）。
/// 在 `Scaffold(appBar: null, body: Stack(...))` 里两者相同，因为 Windows 桌面
/// 全屏播放器的 body 原点就是窗口原点。`viewport` 同理（`MediaQuery.sizeOf`）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 菜单宽度（`design/04` §5.6：240，与 `DESIGN.md` 的对话框量级一致）。
const double _menuWidth = 240;

/// 项高（`design/04` §5.6：36，桌面密度）。
const double _itemHeight = 36;

/// clamp 用的菜单高度估值（`design/04` §5.2）。
///
/// 设计文档写明这是估算值、应由 `LayoutBuilder` 实测。这里保留估值只用来推算
/// **左上角**（菜单最终多高取决于内容，见 [_PlayerContextMenuState.build]），
/// 同时把「真实高度」交给布局约束：菜单高度上限是 `视口高 - 左上角 - 边距`。
/// 两者合起来保证 **菜单永远整块落在窗口内**：估值偏小只会让菜单更早开始
/// 内部滚动，不会让它伸出窗口下沿——这正是 `design/04` §5.2 要防的那个
/// 「右下角右键 → 部分项不可点」缺陷。
const double _estimatedMenuHeight = 420;

/// 菜单与窗口边缘的最小留白（`design/04` §5.2 的 `8`）。
const double _viewportMargin = AppSpace.sm;

/// 菜单里的一项。
class PlayerMenuItem {
  const PlayerMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.children = const [],
    this.onSelect,
  });

  final String id;
  final String label;
  final IconData? icon;

  /// 当前生效的项（当前倍速 / 当前画面模式 / 已开启的屏显项）。
  ///
  /// **必须可见**：这是隐藏式菜单最容易丢的信息
  /// （`DESIGN.md` 关于筛选面板的同类教训：「必须显示已生效」）。
  final bool selected;

  final bool enabled;

  /// 非空表示这是可**就地展开**的子菜单（`design/04` §5.5）。
  ///
  /// 就地展开而不是飞出式子菜单：飞出要处理「飞出后超出窗口」「鼠标斜向移动
  /// 丢失 hover」两个经典难题，而屏显的 7 个开关本来就需要一块区域。
  final List<PlayerMenuItem> children;

  final VoidCallback? onSelect;
}

/// 菜单的一个分组。
class PlayerMenuSection {
  const PlayerMenuSection({required this.title, required this.items});

  final String title;
  final List<PlayerMenuItem> items;
}

/// 把菜单左上角约束在窗口内（`docs/phase8/design/04` §5.2）。
///
/// 为什么必须 clamp：在画面右下角右键，菜单会溢出窗口、部分项不可点——
/// 这是桌面菜单的经典缺陷。
///
/// 菜单比窗口还大时**贴左上角留白**而不是抛异常：`num.clamp` 在
/// `lowerLimit > upperLimit` 时会断言失败（debug 下直接抛），
/// 而「窗口比菜单还小」是真实存在的（窄窗口、用户把窗口拖到很矮）。
Offset clampMenuOrigin({
  required Offset anchor,
  required Size viewport,
  required Size menuSize,
}) {
  final maxX = viewport.width - menuSize.width - _viewportMargin;
  final maxY = viewport.height - menuSize.height - _viewportMargin;
  return Offset(
    _clampStart(anchor.dx, maxX),
    _clampStart(anchor.dy, maxY),
  );
}

/// 单个轴上的 clamp：可用空间不足一个留白时退回留白本身。
double _clampStart(double value, double maxStart) =>
    maxStart <= _viewportMargin ? _viewportMargin : value.clamp(_viewportMargin, maxStart);

/// 右键菜单。
///
/// **返回的是一个 `Positioned`**：调用方必须把它直接放进**页内 `Stack`**
/// （`design/04` §3.3 的第 4 层），不要放进 `Column`，也不要指望它自建浮层。
///
/// 菜单层由两个兄弟组成（见 `player_page.dart`）：
/// 1. `Positioned.fill` + `GestureDetector(onTap: 关闭)`：点外关闭；
/// 2. 本 widget：菜单本体。
///
/// 所以 [onDismiss] 由**调用方**持有：本 widget 不吞指针也不抢焦点
/// （`design/04` §5.3、§5.1 要求菜单打开时右键仍能移动菜单，那需要页面层的
/// `onSecondaryTapDown` 还能收到事件，全屏遮罩不能由菜单本体自己铺）。
class PlayerContextMenu extends StatefulWidget {
  const PlayerContextMenu({
    super.key,
    required this.anchor,
    required this.viewport,
    required this.sections,
    required this.onDismiss,
  });

  /// 菜单左上角的期望位置（父 `Stack` 坐标，通常是右键的 `globalPosition`）。
  ///
  /// 会被 [clampMenuOrigin] 拉回窗口内。
  final Offset anchor;

  /// 窗口尺寸（`MediaQuery.sizeOf(context)`），用于 clamp 与高度上限。
  final Size viewport;

  final List<PlayerMenuSection> sections;

  /// 菜单关闭回调。
  ///
  /// **本 widget 目前不调用它**：点外关闭由调用方的全屏遮罩完成，`Esc` 由
  /// 调用方的内层 `CallbackShortcuts` 完成（`design/04` §5.3）。保留这个参数
  /// 是为了让菜单层的「关闭」只有一个入口——菜单层要加其它关闭途径
  /// （例如未来的键盘导航取消）时不必再改调用方签名。
  final VoidCallback onDismiss;

  @override
  State<PlayerContextMenu> createState() => _PlayerContextMenuState();
}

class _PlayerContextMenuState extends State<PlayerContextMenu> {
  /// 就地展开的子菜单 id 集合（`design/04` §5.5）。
  final Set<String> _expanded = {};

  /// 菜单宽度：窗口比 240 还窄时收窄，保证整块在窗口内（`design/04` §5.2）。
  double get _width => math.min(
    _menuWidth,
    math.max(0, widget.viewport.width - 2 * _viewportMargin),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = _width;
    final origin = clampMenuOrigin(
      anchor: widget.anchor,
      viewport: widget.viewport,
      menuSize: Size(width, _estimatedMenuHeight),
    );
    // 真实高度由内容决定，所以上限必须按**算出来的左上角**再量一次：
    // 只按视口高给上限（`视口高 - 16`）时，一个 900px 高、左上角在 472 的菜单
    // 会伸到 1356 —— 溢出窗口下沿且滚不到。上限取到左上角以下的空间，
    // 菜单就永远整块落在窗口内，超出部分改为内部滚动。
    final maxHeight = math.max(
      0.0,
      widget.viewport.height - origin.dy - _viewportMargin,
    );

    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Material(
          // elevation 0 + 无阴影：`DESIGN.md` 的 The Zero-Elevation Rule。
          // 层级靠更亮的表面 + 发丝边表达，不靠投影。
          elevation: 0,
          color: AppPalette.nightSurface3.withValues(alpha: 0.96),
          // 发丝边画在 `shape` 上而不是另包一层 `DecoratedBox`。
          //
          // 如实说明：**这不是在修一个视觉缺陷**。实测两种写法在相同整数偏移下
          // 渲染结果逐像素相同（115200 个通道无一不同，边缘均为 `(35,43,69)`），
          // 所以我先前的「会被裁成半像素」猜想是**错的**。
          //
          // 保留 `shape` 的真实理由是可断言性：圆角、边宽、边色变成
          // `Material.shape` 上可直接读的属性，测试不必去翻内层 `DecoratedBox`。
          // （`BorderSide` 默认 `strokeAlignInside = -1.0`，边落在内测。）
          // `DESIGN.md` The Hairline Rule。
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final section in widget.sections) ...[
                  _sectionTitle(theme, section.title),
                  for (final item in section.items) ..._itemWidgets(item),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.sm,
      AppSpace.md,
      AppSpace.xs,
    ),
    child: Text(
      title,
      // 分组标题用 `labelSmall` + `onSurfaceVariant`，与列表项副标题一致
      // （`design/04` §5.6）。
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );

  List<Widget> _itemWidgets(PlayerMenuItem item) {
    final widgets = <Widget>[_row(item)];
    if (item.children.isNotEmpty && _expanded.contains(item.id)) {
      for (final child in item.children) {
        // 只支持**一级**子菜单（`design/04` §4.1）。
        //
        // 为什么显式断言而不是递归渲染：递归会让菜单可以无限加深，
        // 而本层的宽度是固定的 240——第二层再缩进就没有可读空间了。
        // 更要紧的是：`_row` 会给任何 `children` 非空的项画一个展开箭头，
        // 若允许第二层存在却不渲染它的孩子，用户会看到一个**点了没反应**的箭头。
        // 与其做半套，不如在构造期就拒绝。
        assert(
          child.children.isEmpty,
          '右键菜单只支持一级子菜单：项 "${child.id}" 自己还有 children（design/04 §4.1）',
        );
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.lg),
            child: _row(child, indent: true),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _row(PlayerMenuItem item, {bool indent = false}) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final hasChildren = item.children.isNotEmpty;
    final isOpen = _expanded.contains(item.id);
    // 选中态用星等琥珀前景，其余用 onSurface。
    //
    // **禁用不能抹掉选中态**（`DESIGN.md:373`：「禁用只降低强调，不能抹掉状态」；
    // 该条来自一次真实用户反馈——把 `onTap == null` 一律当成静态标签，
    // 导致整排控件「长得一模一样且点不动」）。
    // 所以「选中 + 禁用」是**把琥珀压暗**而不是换成中性灰：
    // 仍能看出「这一项是选中的，只是现在不可用」。
    // 「未选中 + 禁用」没有状态要保留，沿用原来的 onSurfaceVariant @ 0.5。
    final color = item.selected
        ? (item.enabled
              ? semantic.magnitude
              : semantic.magnitude.withValues(alpha: 0.5))
        : (item.enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5));

    return InkWell(
      key: ValueKey('player-menu-item-${item.id}'),
      onTap: !item.enabled
          ? null
          : () {
              if (hasChildren) {
                // 就地展开/收起（`design/04` §5.5）；带子菜单的项本身不发动作，
                // 否则「展开」和「执行」会撞在同一次点击上。
                setState(() {
                  if (!_expanded.remove(item.id)) _expanded.add(item.id);
                });
                return;
              }
              item.onSelect?.call();
            },
      child: SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: EdgeInsets.only(
            left: (indent ? AppSpace.sm : 0) + AppSpace.md,
            right: AppSpace.md,
          ),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 18, color: color),
                const SizedBox(width: AppSpace.sm),
              ],
              Expanded(
                child: Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.selected)
                Icon(Icons.check, size: 16, color: semantic.magnitude),
              if (hasChildren)
                Icon(
                  isOpen ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: color,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
