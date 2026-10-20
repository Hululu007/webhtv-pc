/// 浏览页：首页/分类 + 详情（§17.2 首页/分类页、详情页）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/episode_range.dart';
import '../core/history_view.dart';
import '../core/poster_badge.dart';
import '../core/protocol.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_title.dart';
import '../services/ai_episode_season_service.dart';
import '../services/spider_router.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/tmdb_state.dart';
import 'ai_settings_page.dart';
import 'app.dart';
import 'config_pages.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'tmdb_detail_page.dart';
import 'tmdb_detail_view.dart';
import 'common.dart';
import 'scroll_behavior.dart';
import 'tmdb_widgets.dart';
import 'tokens.dart';

class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.hasConfig) {
      return const _EmptyHint(
        title: '还没有导入配置',
        message: '请点击顶栏「导入配置」，支持 URL、本地文件和 JSON 文本三种方式。',
      );
    }
    final site = state.selectedSite;
    if (site == null) {
      return const _EmptyHint(title: '请选择站点', message: '点击顶栏「选择站点」挑选一个可运行的站点。');
    }
    final availability = state.siteItems
        .where((item) => item.site.key == site.key)
        .map((item) => item.availability)
        .firstWhereOrNull();
    if (availability != null && !availability.available) {
      return _UnsupportedSiteHint(site: site, availability: availability);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 分类条固定（页面级上下文，永远可达），筛选条与网格一起滚动。
        _BrowseTabBar(state: state, site: site),
        Expanded(child: _VodGrid(state: state)),
      ],
    );
  }
}

/// 海报网格度量。
///
/// 竖版海报标准比例是 `2:3`，网格按这个比例反推格子高度（见
/// [_VodGrid._gridDelegate]）。
const double _posterTargetWidth = 150;
const double _posterSpacing = 14;
const double _posterGridPadding = 16;

/// 海报卡片文字区（标题 + 备注）的固定高度。
///
/// 给死高度而不是让它自适应：格子高度由「海报 2:3 + 本值」精确算出，文字区一旦
/// 浮动，海报就会被压成非 2:3。
const double _posterCaptionHeight = 40;

/// 顶部分类条（§17.1 分类区）：横向标签 + 选中下划线，**固定在网格上方**。
///
/// 为什么不再用「280px 左侧栏 + 垂直分类列表」（5559 真机实测 木偶[盘]）：
/// 1. 筛选维度渲染在侧栏里会**吃掉整栏高度**——该站点 5 个维度里仅「剧情」一组
///    就有 17 项，于是侧栏被筛选填满、真正的分类列表被挤出可视区（用户看到的
///    「分类不见了」正是这个）；
/// 2. 侧栏还带 `type=4 · key=02544b32…` 这类**内部调试字段**，不该出现在 UI 上；
/// 3. 分类是页面级上下文，横排在内容区顶部可以用满宽度，窗口缩放时也不挤压网格。
class _BrowseTabBar extends StatefulWidget {
  const _BrowseTabBar({required this.state, required this.site});

  final AppState state;
  final Site site;

  @override
  State<_BrowseTabBar> createState() => _BrowseTabBarState();
}

class _BrowseTabBarState extends State<_BrowseTabBar> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final home = state.homeResult;
    final classes = home?.classes ?? const <VodClass>[];
    // 首页有推荐内容才保留「默认推荐」标签（否则它只是个空态入口）。
    final hasHomeList = home?.list.isNotEmpty ?? false;
    final selected = state.selectedTypeId;
    final loading = state.contentPhase == LoadPhase.loading;
    // 当前分类可用的筛选维度。空 = 这个分类没有筛选，入口按钮**不渲染**。
    final filters = _VodGrid.filtersFor(state, selected);

    return Container(
      height: 46,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            // 桌面端的竖滚轮在 Flutter 里不驱动横向滚动，需要显式转一次，
            // 否则分类多到溢出时滚轮推不动这条（§17.4 鼠标可用）。
            // 鼠标左右拖由 `HorizontalMouseDrag` 打开（同样 §17.4）。
            child: HorizontalMouseDrag(
              child: _WheelScroll(
                controller: _controller,
                child: SingleChildScrollView(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 首页**没有推荐内容**时不显示「默认推荐」标签：那个标签点进去
                      // 只有空态（实测 126 站点里 40 个如此），留在条上只会误导用户。
                      if (hasHomeList)
                        _BrowseTab(
                          key: const ValueKey('browse-tab-default'),
                          label: '默认推荐',
                          selected: selected == null,
                          onTap: loading ? null : state.selectDefaultListing,
                        ),
                      for (final item in classes)
                        _BrowseTab(
                          key: ValueKey('browse-tab-${item.typeId}'),
                          label: item.typeName,
                          selected: selected == item.typeId,
                          onTap: loading
                              ? null
                              : () => state.loadCategory(item.typeId),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 筛选入口：**只有真的有筛选维度时才出现**。
          //
          // 「没有筛选的分组就不应该有筛选按钮」（用户反馈 2026-10-13）——
          // 一个点了什么也没有的按钮比没有按钮更糟。
          if (filters.isNotEmpty)
            _FilterMenuButton(state: state, groups: filters),
          IconButton(
            key: const ValueKey('browse-refresh'),
            tooltip: selected == null ? '刷新首页' : '刷新当前分类',
            onPressed: loading
                ? null
                : () => selected == null
                      ? state.loadHome(widget.site)
                      : state.loadCategory(selected),
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 单个分类标签：选中态用主色文字 + 下划线，未选中态为弱化文字。
///
/// 不用 `ChoiceChip` / `Tab`：Material 的 chip 自带实心底与描边，一行十几个会显得很
/// 重；这里需要的是「文字 + 细下划线」的轻量导航（对齐主流媒体库的分类条）。
class _BrowseTab extends StatelessWidget {
  const _BrowseTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: scheme.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 14,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              height: 3,
              width: 20,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把纵向滚轮增量转成横向滚动（桌面端专用）。
///
/// Flutter 的横向 `Scrollable` 只消费 `scrollDelta.dx`，而普通鼠标只有 `dy`，
/// 于是「滚轮推不动横向标签条」。这里把明显偏向纵向的增量自己转成横向位移；
/// 横向分量更大时（触控板横扫）仍交给内部滚动视图处理，避免双重滚动。
class _WheelScroll extends StatelessWidget {
  const _WheelScroll({required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final delta = event.scrollDelta;
        if (delta.dx.abs() >= delta.dy.abs()) return;
        if (!controller.hasClients) return;
        final position = controller.position;
        final target = (position.pixels + delta.dy).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (target == position.pixels) return;
        controller.jumpTo(target);
      },
      child: child,
    );
  }
}

/// 分类条上的**筛选入口按钮**：点击后悬浮显示筛选面板。
///
/// 设计取舍（用户反馈 2026-10-13：「筛选区域不再默认展示，加一个按钮点击后
/// 悬浮显示」）：
/// - **按需出现**：`groups` 为空时调用点根本不渲染这个按钮——没有筛选的分组
///   不该有一个点了没反应的按钮；
/// - **悬浮而不是常驻**：面板不占布局、不推挤海报网格。原来常驻时多维度要吃掉
///   内容区顶部 150~200px；
/// - **必须显示"已生效"**：面板藏起来之后，用户看不到自己选过什么。所以有生效
///   筛选时按钮**染成星等琥珀 + 数字角标**，一眼知道"现在筛着 2 个维度"；
/// - **「重置筛选」放进面板**：它属于筛选状态，和筛选控件在一起才不会找不到。
class _FilterMenuButton extends StatelessWidget {
  const _FilterMenuButton({required this.state, required this.groups});

  final AppState state;
  final List<VodFilterGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final active = state.categoryFilters;
    final activeCount = active.length;

    return MenuAnchor(
      // 点外部自动关闭；面板内点 chip 不会关（`MenuAnchor` 只在选中 menu item
      // 或点外部时关，这里的 chip 是普通控件）。
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          theme.colorScheme.surfaceContainerHigh,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: AppSpace.sm),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: 520,
          child: ConstrainedBox(
            // 维度多时面板自身滚动，不撑破窗口。
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              child: _FilterPanelBody(state: state, groups: groups),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        final open = controller.isOpen;
        return Padding(
          padding: const EdgeInsets.only(right: AppSpace.xs),
          child: TextButton.icon(
            key: const ValueKey('category-filter-menu'),
            onPressed: () =>
                open ? controller.close() : controller.open(),
            icon: Icon(
              Icons.tune,
              size: 18,
              color: activeCount > 0 ? semantic.magnitude : null,
            ),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('筛选'),
                if (activeCount > 0) ...[
                  const SizedBox(width: AppSpace.xs),
                  // 数字角标：面板藏起来后，这是"筛了几项"的唯一提示。
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: semantic.magnitude,
                      borderRadius: AppRadius.pillAll,
                    ),
                    child: Text(
                      '$activeCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        // 琥珀底上用夜空墨色：琥珀是亮色，白字对比度不足。
                        color: AppPalette.nightGround,
                        fontWeight: AppWeight.title,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            style: TextButton.styleFrom(
              foregroundColor: activeCount > 0
                  ? semantic.magnitude
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

/// 悬浮面板的内容：每个维度一行「等宽标签 + 横向 chip」+ 底部重置。
///
/// 布局对齐主流桌面媒体库：行首是该维度的标签列（各行**等宽**，所以 chip 左边缘
/// 对齐），右侧 chip 自适应换行。选中态是主色淡底 + 主色文字，未选中是弱化纯文字。
///
/// 为什么不用「每条一行 + 勾选框」：勾选框 + 实底高亮是设置表单的视觉语言，
/// 不像媒体库的筛选条；横向 chip 换行后「剧情」这类 17 项的维度只占 3 行。
class _FilterPanelBody extends StatelessWidget {
  const _FilterPanelBody({required this.state, required this.groups});

  final AppState state;
  final List<VodFilterGroup> groups;

  /// 标签列宽度的上下限：短名（「地区」）不留大片空白，长名（「资源类型」）
  /// 也不能无限挤压 chip 区。
  static const double _minLabelWidth = 40;
  static const double _maxLabelWidth = 88;

  @override
  Widget build(BuildContext context) {
    final labelWidth = _measureLabelWidth(context);
    // 筛选 chip **始终可点**。
    //
    // 原来这里在 `contentPhase == loading` 时把整条筛选栏禁用，理由写的是
    // 「连点会把多个响应乱序写回状态」。但那个理由**不成立**：状态层已经用
    // `_categoryRunId` 作废在途响应（`app_state.dart:1442`、`:1459`），
    // 乱序写回早就被挡住了。代价却很实在——站点慢的时候（桥接站、网盘站，
    // 实测 0.3~2s）整条筛选栏在请求期间完全点不动，用户看到的就是
    // 「筛选按钮点击没反应，不会筛选」（用户反馈 2026-10-11）。
    //
    // 即时生效的控件不应该在每次生效的过程中把自己关掉。
    const enabled = true;
    final active = state.categoryFilters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final group in groups)
          _FilterRow(
            group: group,
            labelWidth: labelWidth,
            selectedValue: active[group.key] ?? '',
            enabled: enabled,
            onSelect: (value) => state.setCategoryFilter(group.key, value),
          ),
        if (active.isNotEmpty) ...[
          const Divider(height: AppSpace.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('category-filter-clear'),
              onPressed: state.clearCategoryFilters,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('重置筛选'),
            ),
          ),
        ],
      ],
    );
  }

  /// 标签列宽度 = 所有维度名里最宽者 + 间距，夹在 [min, max] 之间。
  ///
  /// 用固定宽度会让「资源类型」被截断或「地区」后留一片空白；各行宽度不一致又会让
  /// chip 左边缘参差。按实际文本量一次即可两全。
  double _measureLabelWidth(BuildContext context) {
    final style = _filterLabelStyle(context);
    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final group in groups) {
      final painter = TextPainter(
        text: TextSpan(text: group.name, style: style),
        maxLines: 1,
        textDirection: direction,
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    return (widest + 10).clamp(_minLabelWidth, _maxLabelWidth);
  }
}

/// 行首维度标签的样式（筛选条各行的标签列共用）。
TextStyle _filterLabelStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall!.copyWith(
    fontSize: 13,
    height: 1.2,
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// 单个筛选维度：一行「标签 + chip 换行区」。
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.group,
    required this.labelWidth,
    required this.selectedValue,
    required this.enabled,
    required this.onSelect,
  });

  final VodFilterGroup group;
  final double labelWidth;
  final String selectedValue;
  final bool enabled;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // 站点自带「全部」（`v` 为空串）时不重复补；缺失时必须补，否则该维度一旦
    // 选中就没有任何入口能取消它（只能整条重置）。
    //
    // 先按 `value` 去重：chip 的 key 是 `category-filter-<维度>-<值>`，
    // 一旦站点数据里出现两个同值选项（实测有站点给出两个空值选项），key 就重复，
    // Flutter 抛 `Duplicate keys found` —— **在真机上那是一屏红**。
    // 同值选项在语义上本来就是同一个筛选项，去重不丢信息，也保住了 key 的格式
    // （外部没有依赖 key 的测试，但没必要改）。
    final options = <VodFilterOption>[];
    final seenValues = <String>{};
    for (final option in group.options) {
      if (seenValues.add(option.value)) options.add(option);
    }
    final hasAll = options.any((option) => option.value.isEmpty);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Tooltip(
                message: group.name,
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _filterLabelStyle(context),
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              children: [
                if (!hasAll)
                  _FilterChip(
                    key: ValueKey('category-filter-${group.key}-all'),
                    label: '全部',
                    selected: selectedValue.isEmpty,
                    onTap: enabled ? () => onSelect('') : null,
                  ),
                for (final option in options)
                  _FilterChip(
                    key: ValueKey(
                      'category-filter-${group.key}-${option.value}',
                    ),
                    label: option.name,
                    selected: option.value == selectedValue,
                    onTap: enabled ? () => onSelect(option.value) : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个筛选项 chip：选中为主色淡底 + 主色文字，未选中为弱化纯文字。
///
/// 选中用 `primary` 的**透明度淡化**而不是 `primaryContainer`：后者在深色主题下
/// 是一块很重的实底蓝，十几个维度排下来会异常晦澀；淡化底在深浅两套主题下都能
/// 得到参考实现那种「淡淡一层色块」的观感，而且主色文字对比度始终足够。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: TagChip(
        label: label,
        selected: selected,
        onTap: onTap,
        // 这是可选控件：禁用时也必须保留选中态（见 `TagChip.selectable`）。
        selectable: true,
      ),
    );
  }
}

/// 海报网格区（§17.1 海报网格）：筛选条 + 海报网格 + 滚动加载页脚。
class _VodGrid extends StatelessWidget {
  const _VodGrid({required this.state});

  final AppState state;

  /// 距底部多少像素时提前触发下一页。
  ///
  /// 提前量而不是“贴底”：桥接的网盘聚合站一次请求实测 0.3~2s，等滚到最后一排
  /// 才发请求会让底部出现明显的空窗。
  static const double _prefetchExtent = 700;

  @override
  Widget build(BuildContext context) {
    final result = state.selectedTypeId == null
        ? state.homeResult
        : state.categoryResult;
    final vods = result?.list ?? const <Vod>[];
    // 猫源/部分站点首页只返回分类（`class` 非空）而 `list` 为空，需要用户先点分类。
    // 直接显示"没有内容"会把正常站点误报成空站（实测 126 站点里 40 个如此），
    // 因此按“有无分类”区分两种空态文案。
    final hasClasses = result?.classes.isNotEmpty ?? false;
    final loading = state.contentPhase == LoadPhase.loading;
    // 分页页脚只在分类上下文里出现：首页结果没有分页语义。
    final paged = state.selectedTypeId != null && vods.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ErrorBanner(
              error: state.lastError!,
              onDismiss: state.clearError,
            ),
          ),
        if (state.notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _NoticeBanner(
              message: state.notice!,
              onDismiss: state.clearNotice,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: CustomScrollView(
                    slivers: [
                      // 筛选条**不再常驻**。
                      //
                      // 它原来占内容区顶部 150~200px（多维度时更多），把海报挤下去，
                      // 而多数时候用户并不筛选（用户反馈 2026-10-13：「筛选区域不再
                      // 默认展示」）。现在它归分类条上的「筛选」按钮，点击后**悬浮**
                      // 显示——不占布局、不推挤网格。
                      if (vods.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _emptyState(
                            loading: loading,
                            hasClasses: hasClasses,
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(
                            _posterGridPadding,
                            14,
                            _posterGridPadding,
                            8,
                          ),
                          sliver: SliverGrid(
                            gridDelegate: _gridDelegate(constraints.maxWidth),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _VodCard(
                                key: ValueKey('vod-card-${vods[index].vodId}'),
                                vod: vods[index],
                                onTap: () => _openDetail(context, vods[index]),
                              ),
                              childCount: vods.length,
                            ),
                          ),
                        ),
                      // 刷新首页时旧列表**不被清空**（loadHome 保留 _homeResult），
                      // 此时只压一条细进度条：整页闪成空白会让用户以为断网了。
                      if (loading && vods.isNotEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        ),
                      if (paged)
                        SliverToBoxAdapter(child: _ScrollFooter(state: state)),
                    ],
                  ),
                ),
          ),
        ),
      ],
    );
  }

  /// 滚动到底自动加载下一页。
  ///
  /// 重入靠**状态层**拦（`categoryLoadingMore` / `categoryHasMore`），这里不自己
  /// 记账：滚动通知一帧可能来好几条（update + end），在 UI 里判重很容易漏。
  bool _onScroll(ScrollNotification notification) {
    // 只认最外层列表；嵌套滚动（如筛选条内部）不参与触发。
    if (notification.depth != 0) return false;
    if (notification.metrics.maxScrollExtent - notification.metrics.pixels >
        _prefetchExtent) {
      return false;
    }
    if (state.selectedTypeId == null) return false;
    if (state.contentPhase == LoadPhase.loading) return false;
    if (!state.categoryHasMore || state.categoryLoadingMore) return false;
    unawaited(state.loadMoreCategory());
    return false;
  }

  Widget _emptyState({required bool loading, required bool hasClasses}) {
    if (loading) return const LoadingBlock();
    if (hasClasses) {
      return const _EmptyHint(
        title: '请选择一个分类',
        message:
            '该站点首页只返回分类列表（未提供推荐内容）。'
            '点顶部分类条里的任一项即可加载影片；若分类也为空，再切换站点或更新配置。',
      );
    }
    return const _EmptyHint(
      title: '没有内容',
      message: '该分类返回空列表。若站点不可用，请切换站点或更新配置。',
    );
  }

  /// 网格度量：先按可用宽度定列数与列宽，再由列宽推出格子高度。
  ///
  /// 为什么不用 `SliverGridDelegateWithMaxCrossAxisExtent`：它的 `mainAxisExtent`
  /// 是固定值，窗口变窄时列宽变小、高度不变，海报会被压成非 2:3 或被裁切。
  /// 这里列宽已知，格子高度就能精确算成「海报 2:3 + 文字区」，任何窗口宽度下
  /// 比例都稳定（§17.5 要求窗口缩放布局稳定）。
  static SliverGridDelegate _gridDelegate(double maxWidth) {
    final usable = maxWidth - _posterGridPadding * 2;
    final columns = (usable / (_posterTargetWidth + _posterSpacing))
        .round()
        .clamp(2, 12);
    final cellWidth = (usable - (columns - 1) * _posterSpacing) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _posterSpacing,
      mainAxisSpacing: 8,
      mainAxisExtent: cellWidth * 1.5 + 8 + _posterCaptionHeight,
    );
  }

  /// 取当前分类的筛选维度。
  ///
  /// 三个来源按优先级：分类结果 → 首页结果。
  /// 首页的 `filters` 是按 `type_id` 分组的 map，所以必须用当前 `type_id` 取子集；
  /// 分类请求返回的 `filters` 已经是**该分类自己的**一组（`map` 只有一个键或
  /// 直接就是列表），因此优先用它，拿不到再回退首页。
  /// 当前分类可用的筛选维度（分类结果优先，其次首页）。
  ///
  /// 公开而不是私有：分类条上的筛选入口按钮也要用它来决定**是否渲染**
  /// （没有维度就不该有按钮）。
  static List<VodFilterGroup> filtersFor(AppState state, String? typeId) {
    if (typeId == null) return const [];
    final fromCategory = _groupFor(state.categoryResult, typeId);
    if (fromCategory.isNotEmpty) return fromCategory;
    return _groupFor(state.homeResult, typeId);
  }

  static List<VodFilterGroup> _groupFor(SiteResult? result, String typeId) {
    final filters = result?.filters;
    if (filters == null || filters.isEmpty) return const [];
    final direct = filters[typeId];
    if (direct != null && direct.isNotEmpty) return direct;
    // 某些站点把全部维度放在单个键下（或键名与 type_id 不一致）：
    // 此时只要只有一组就直接用它。
    if (filters.length == 1) return filters.values.first;
    // 多组且没有一组对应当前 type_id：合并全部，但**按维度 key 去重**
    // （去重的原因与取舍见 `mergeFilterGroups` 的文档）。
    return mergeFilterGroups(filters.values);
  }

  Future<void> _openDetail(BuildContext context, Vod vod) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: state, vod: vod),
      ),
    );
  }
}

/// 海报卡片：海报（2:3 圆角，带年份/评分角标）+ 居中标题 + 备注。
///
/// 标题居中、只用一档弱化色——参照实现的卡片就是「图 + 居中一行字」，不加边框
/// 与卡片底色，密集排列时比带底色的卡片干净得多。
///
/// 角标（用户提供参考截图 2026-10-09）：左上角**年份**、右下角**评分**。
/// 取值与判定在 `core/poster_badge.dart`（纯逻辑，含「remarks 不一定是评分」的
/// 关键约束：网盘站给的是 `全29集`，那种情况不能当评分画角标）。
class _VodCard extends StatelessWidget {
  const _VodCard({super.key, required this.vod, required this.onTap});

  final Vod vod;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = PosterBadge.yearOf(vod);
    final score = PosterBadge.scoreOf(vod);
    final remark = PosterBadge.textRemarkOf(vod);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `AspectRatio` 而不是 `Expanded`：海报比例由比例盒子保证，文字区再高
          // 也不会把海报压成非 2:3。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: vod.vodPic),
                  if (year != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _PosterBadge(
                        text: year,
                        key: const ValueKey('poster-badge-year'),
                      ),
                    ),
                  if (score != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _PosterBadge(
                        text: score,
                        highlight: true,
                        key: const ValueKey('poster-badge-score'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            // 放大字号（无障碍）时只缩不放：文字区高度是固定值，不夹住就会溢出格子。
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.25,
              child: Column(
                children: [
                  Text(
                    vod.vodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  if (remark != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      remark,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        height: 1.2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 海报角标（年份 / 评分）。
///
/// 用半透明黑底 + 白字而不是主题色：海报画面本身色彩不可控（实测有高饱和海报），
/// 半透明黑底在任何海报上都能保证白字可读，且不与主色冲突。
class _PosterBadge extends StatelessWidget {
  const _PosterBadge({super.key, required this.text, this.highlight = false});

  final String text;

  /// 评分角标用暖色强调（年份是中性信息）。
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xCCE8830C) : const Color(0x99000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 滚动加载页脚：[加载中] / [加载更多] / [没有更多了]。
///
/// 为什么除了自动触发还要有按钮：第一页不足一屏时（实测站点只回 3~6 条的短
/// 分类），列表不产生任何滚动，滚动通知永远不触发，下一页就永远拿不到。
/// 按钮是这种「无滚动可滚」场景的唯一入口，同时也给不习惯无限滚动的用户一个
/// 明确的下一步。
class _ScrollFooter extends StatelessWidget {
  const _ScrollFooter({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.categoryLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: LoadingBlock(center: false),
          ),
        ),
      );
    }
    if (state.categoryHasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
        child: Center(
          child: TextButton.icon(
            key: const ValueKey('category-load-more'),
            onPressed: state.contentPhase == LoadPhase.loading
                ? null
                : state.loadMoreCategory,
            icon: const Icon(Icons.expand_more, size: 18),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 20),
      child: Center(
        child: Text(
          '已经到底啦',
          key: const ValueKey('category-list-end'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 详情页（§17.2 详情页）。
class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.state,
    required this.vod,
    this.historyFlag = '',
    this.historyEpisodeId = '',
  });

  final AppState state;
  final Vod vod;

  /// 历史命中的线路 flag（空串 = 未传入）。
  ///
  /// 由历史页传入**用户点的那一条**记录，优先于页面自己查到的"最近一条"：
  /// 同一部剧有多条历史时，点旧记录却续新记录是错的
  /// （`docs/phase6/design/02` §7.1）。
  final String historyFlag;

  /// 历史命中的集入口目标（空串 = 未传入）。
  final String historyEpisodeId;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  /// 当前选中线路的 `flag`（`04` §3.1 ④）。
  ///
  /// 点击线路条即切换，下方剧集卡片随之变成该线路的集（对齐上游 `@id/flag`）。
  /// 空串表示「尚未选定」，此时默认取第一条线路。
  String _selectedLineFlag = '';

  /// 剧集卡片是否倒序（对齐上游 `@id/episodeReverse`）。
  bool _episodesReversed = false;

  /// 剧集是否网格模式（对齐上游 `@id/episodeViewMode`）。
  bool _episodeGridMode = false;

  /// 选集区间下标（`docs/phase6/design/03` §4.4）。
  ///
  /// 页面级临时状态（与 `_episodesReversed` / `_episodeGridMode` 同级），
  /// **不进 `AppState`**：它是纯展示状态，跨页面保留没有意义。
  int _rangeIndex = 0;

  /// 用户是否**手动**点过区间 chip。
  ///
  /// 手动选过之后切集不再重置区间（对齐上游 `manualEpisodeRange`）：
  /// 用户的显式意图优先于自动跟随。
  bool _manualRange = false;

  /// 上一次渲染时的季度序号，用于检测切季（`design/03` §5.1）。
  int _lastSeasonEpoch = -1;

  @override
  void initState() {
    super.initState();
    // 必须监听 AppState：详情请求在页面挂载后才完成，不重建就永远停在加载中
    // （实测「第一次进去说没有线路、第二次一直转圈」的直接成因）。
    // 搜索页、Spider 管理页同样监听了各自的状态变更。
    widget.state.addListener(_onStateChanged);
    // TMDB 区块也需监听（异步匹配/详情完成后重建，`04` §3.3）。
    widget.state.tmdb.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.state.loadDetail(widget.vod);
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    widget.state.tmdb.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _closeDetail() {
    // 离开详情页时清掉全局详情状态（§8.3）：结果与所选影片是页面级临时状态，
    // 不清理会让下一次进入详情页先渲染上一部剧的线路（实测串剧）。
    widget.state.clearDetail();
    Navigator.of(context).pop();
  }

  /// 打开手动匹配弹窗（`04` §5.1）。
  Future<void> _openMatchDialog() async {
    final state = widget.state;
    final vod = _currentVod;
    final item = await showDialog<TmdbItem>(
      context: context,
      builder: (_) => TmdbMatchDialog(
        initialQuery: state.tmdb.item?.title ?? vod?.vodName ?? '',
        search: state.searchTmdb,
        resolveProviderId: state.resolveTmdbProviderId,
      ),
    );
    if (item == null || !mounted) return;
    await state.matchTmdbManual(item: item, sourceTitle: vod?.vodName);
  }

  /// 打开季度绑定弹窗（`04` §5.2）。
  Future<void> _openOverviewDialog(String text) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('简介'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSeasonDialog() async {
    final state = widget.state;
    final tmdb = state.tmdb;
    final counts = tmdb.seasonEpisodeCounts;
    final seasons = counts.keys.toList()..sort();
    if (seasons.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('TMDB 未返回季度信息，暂时无法手动绑定季度')));
      return;
    }
    final line = tmdb.sourceLine;
    // 【必须用**无类型**路由 + `decodeSeasonChoice`，不能 `showDialog<TmdbSeasonChoice>`】
    //
    // 弹窗 pop 的是 `_SeasonChoice`（私有枚举）或 `int`（季号），两者都不是
    // `TmdbSeasonChoice`。若把路由声明成 `showDialog<TmdbSeasonChoice>`，
    // `Navigator.pop` 会因「结果类型与路由期望类型不符」抛异常，
    // 对话框结果恒为 `null`——用户点“第 2 季”看起来就是“点了没反应”
    // （Phase 4 起就存在的缺陷，2026-10-16 由 L3 `phase6_ai_season_flow_test`
    // 驱动真实弹窗时揪出）。
    //
    // `decodeSeasonChoice` 本来就是为这一步写的转换函数，此前**从未被接线**。
    final raw = await showDialog<Object?>(
      context: context,
      builder: (_) => TmdbSeasonDialog(
        tmdbSeasons: seasons,
        seasonCounts: counts,
        sourceEpisodeCount: line?.episodeCount ?? 0,
        currentSeason: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
        canAutoSlice: tmdb.canAutoSlice,
        aiReady: state.aiReady,
      ),
    );
    if (raw == null || !mounted) return;
    final choice = decodeSeasonChoice(raw);
    if (choice == null || !mounted) return;

    // **分流必须在 bindTmdbSeason 之前**（`docs/phase6/design/04` §7.1.1）：
    // `bindingModeOf` 对 AI 两项返回 null，与 `TmdbSeasonAuto` 同值，而 null 的
    // 含义是「清除手动绑定」。直接喂给 bindTmdbSeason 会让用户点「AI 识别」
    // 或「去配置 AI」时把已有绑定静默清掉。
    if (choice is TmdbSeasonAiSettings) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => AiSettingsPage(state: state)),
      );
      return;
    }
    if (choice is TmdbSeasonAi) {
      await _runAiSeasonAnalysis();
      return;
    }

    await state.bindTmdbSeason(choice);
    if (!mounted) return;
    await state.reloadTmdb();
  }

  /// 跑一次 AI 集季分析并走预览确认（`docs/phase6/design/04` §7.2–§7.5）。
  Future<void> _runAiSeasonAnalysis() async {
    final state = widget.state;
    final tmdb = state.tmdb;
    final vod = _currentVod;
    final tmdbLine = tmdb.sourceLine;
    if (vod == null || tmdbLine == null || tmdbLine.episodeCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前线路没有可分析的剧集')),
      );
      return;
    }

    // 用 tmdb 线路自己的集名重建集列表，而**不是**取 UI 的 `_activeLine`：
    // 这样 `episodes.length` 与快照里的 `episodeCount` 必然同源（§7.5 的
    // 前后比对才有意义），也不会因 UI 线路选中态与 tmdb 态短暂不一致而错位。
    final episodes = [
      for (var i = 0; i < tmdbLine.episodeNames.length; i++)
        VodEpisode(
          name: tmdbLine.episodeNames[i],
          url: i < tmdbLine.episodeUrls.length ? tmdbLine.episodeUrls[i] : '',
        ),
    ];

    // 快照（`04` §7.5）：分析可能耗时几十秒，期间用户可能切了线路或换了站点，
    // 应用前必须比对，否则会把结果写到新线路上。
    final snapshotFlagKey = tmdbLine.flagKey;
    final snapshotCount = tmdbLine.episodeCount;

    final service = AiEpisodeSeasonService(config: state.aiConfig);
    var canceled = false;
    // 提前拿住 navigator：要等 `await` 之后才能关进度框，届时 `context` 可能已失效
    // （也因此不能用 `Navigator.of(context, ...)` 去做那件事）。
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('ai-season-progress'),
          title: const Text('AI 正在分析剧集结构…'),
          content: const Text('分析期间不会改动任何绑定。'),
          actions: [
            TextButton(
              key: const ValueKey('ai-season-cancel'),
              onPressed: () {
                canceled = true;
                service.cancel();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );

    final result = await service.analyze(
      title: vod.vodName,
      flagName: tmdbLine.sourceFlag,
      episodes: episodes,
      seasonCounts: tmdb.seasonEpisodeCounts,
    );
    service.dispose();

    // 只在取消路径下**跳过**关闭进度框。
    //
    // 【两处都不能照抄计划的写法】
    //
    // 1. 顺序：计划写的是「先 `maybePop()` 再判 `canceled`」。用户点取消时进度框
    //    已由取消按钮自己 pop 掉了，此时 `maybePop()` 弹掉的是**详情页本身**
    //    （用户点「取消」却被退出详情页）。
    //
    // 2. `pop()` 而不是 `maybePop()`：`maybePop()` 会调 `Route.willPop()`，
    //    而 `ModalRoute.willPop()` 断言本路由的 `_ModalScopeState` 已构建
    //    （`routes.dart`: `'scope != null'`）。假服务端回得快时，`await` 在
    //    进度框的**第一帧之前**就返回了，`maybePop()` 当场断言失败
    //    （实测 `phase6_ai_season_flow_test`）。`pop()` 不经过 `willPop()`，
    //    因此不依赖“已经渲染过”。
    //
    // 安全性：进度框 `barrierDismissible: false`，唯一的退出路径就是取消按钮
    // （会置 `canceled`），所以 `!canceled` 时栈顶必然仍是进度框。
    if (!canceled && mounted) navigator.pop();
    if (canceled || !mounted) return;

    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_aiFailureText(result.reason))),
      );
      return;
    }

    await _showAiPreview(
      result: result,
      snapshotFlagKey: snapshotFlagKey,
      snapshotCount: snapshotCount,
    );
  }

  /// AI 结果预览确认（§7.3）与应用（§7.4）。**必经确认才落盘。**
  Future<void> _showAiPreview({
    required AiSeasonAnalysis result,
    required String snapshotFlagKey,
    required int snapshotCount,
  }) async {
    final previewOnly = result.mode == AiSeasonMode.explicitMapping;
    final confirmed = await showDialog<bool>(
      context: context,
      // 包一层**带 key 的** `RepaintBoundary`：证据截图必须能拍到这张对话框本身。
      //
      // 【为什么非加不可】每个路由（含 dialog）在 `Navigator` 里各有自己的
      // `RepaintBoundary`，**没有任何一个** boundary 同时包含页面与对话框的
      // 内容。所以「拍整窗」并不存在：默认取第一个 boundary 只会拍到详情页，
      // 对话框完全不在图里（实测 173791 字节的图里没有预览框）。既有套件
      // 用的是同一个办法：`tmdb_detail_visual_flow_test` 为图片查看器加了
      // `tmdb-photo-viewer-boundary`，截图时按 key 指定这一层。
      builder: (context) => RepaintBoundary(
        key: const ValueKey('ai-season-preview-boundary'),
        child: AlertDialog(
          key: const ValueKey('ai-season-preview'),
          title: const Text('AI 剧集 / 季度分析建议'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_aiModeLabel(result.mode)} · '
                  '${(result.confidence * 100).round()}%',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (result.seasonNumber >= 0)
                  Text(
                    result.seasonNumber == 0
                        ? '特别篇'
                        : '第 ${result.seasonNumber} 季',
                  ),
                if (result.summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(result.summary),
                ],
                for (final warning in result.warnings) ...[
                  const SizedBox(height: 4),
                  Text('• $warning'),
                ],
                if (previewOnly) ...[
                  const SizedBox(height: 12),
                  Text(
                    '本版本仅预览，不会写入绑定。',
                    key: const ValueKey('ai-season-preview-only'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(previewOnly ? '知道了' : '取消'),
            ),
            if (!previewOnly)
              FilledButton(
                key: const ValueKey('ai-season-apply'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('应用建议'),
              ),
          ],
        ),
      ),
    );
    if (confirmed != true || previewOnly || !mounted) return;

    // 快照校验（`04` §7.5）。
    final current = widget.state.tmdb.sourceLine;
    if (current == null ||
        current.flagKey != snapshotFlagKey ||
        current.episodeCount != snapshotCount) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('线路已变化，AI 建议不再适用，请重新分析')),
      );
      return;
    }

    switch (result.mode) {
      case AiSeasonMode.singleSeason:
        await widget.state.bindTmdbSeason(
          TmdbSeasonNumber(result.seasonNumber),
        );
      case AiSeasonMode.keepOriginal:
        await widget.state.bindTmdbSeason(const TmdbSeasonKeepOriginal());
      case AiSeasonMode.flatByCounts:
        // 应用前**再校验一次**（`04` §7.4）：AI 说可以，本地校验不过就拒绝。
        if (!widget.state.tmdb.canAutoSlice) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('当前线路集数与 TMDB 季集数不匹配，无法安全自动切分'),
            ),
          );
          return;
        }
        await widget.state.bindTmdbSeason(const TmdbSeasonAutoSlice());
      case AiSeasonMode.explicitMapping:
        return; // 上面已短路，这里只为穷尽 switch。
      case null:
        return;
    }
    if (!mounted) return;
    await widget.state.reloadTmdb();
  }

  static String _aiModeLabel(AiSeasonMode? mode) => switch (mode) {
    AiSeasonMode.singleSeason => '单季',
    AiSeasonMode.flatByCounts => '按集数切片',
    AiSeasonMode.keepOriginal => '保持原始集列表',
    AiSeasonMode.explicitMapping => '逐集映射',
    null => '未知',
  };

  static String _aiFailureText(AiSeasonFailure reason) => switch (reason) {
    AiSeasonFailure.configIncomplete => 'AI 服务未配置完成',
    AiSeasonFailure.noEpisodes => '没有可分析的剧集',
    AiSeasonFailure.http => 'AI 接口返回错误',
    AiSeasonFailure.network => 'AI 网络错误',
    AiSeasonFailure.timeout => 'AI 请求超时',
    AiSeasonFailure.canceled => '已取消',
    AiSeasonFailure.invalidJson => 'AI 返回的不是合法 JSON',
    AiSeasonFailure.invalidMode => 'AI 返回的模式无法识别',
    AiSeasonFailure.invalidSeason => 'AI 给出的季度与 TMDB 不符',
    AiSeasonFailure.unsafeFlatMapping => 'AI 给出的集号映射不完整，已拒绝',
    AiSeasonFailure.invalidMapping => 'AI 的逐集映射不合法，已拒绝',
    AiSeasonFailure.none => 'AI 分析失败',
  };

  /// 本页要用的历史记录。
  ///
  /// 优先级：**构造参数 > 自己查**（`docs/phase6/design/02` §7.1）。
  PlaybackHistory? get _history {
    if (widget.historyFlag.isNotEmpty || widget.historyEpisodeId.isNotEmpty) {
      return PlaybackHistory(
        id: 0,
        siteKey: widget.state.selectedSite?.key ?? '',
        vodId: widget.vod.vodId,
        vodName: widget.vod.vodName,
        vodPic: widget.vod.vodPic,
        flag: widget.historyFlag,
        episodeName: '',
        episodeId: widget.historyEpisodeId,
        positionMs: 0,
        durationMs: 0,
        updatedAt: 0,
      );
    }
    return widget.state.findHistory(
      siteKey: widget.state.selectedSite?.key ?? '',
      vodId: widget.vod.vodId,
    );
  }

  /// 本页的续播目标（线路 + 集下标）。
  ///
  /// 在详情到达后才解析：`_activeLine` 依赖 `lines`，而 `lines` 在详情请求
  /// 返回前可能是列表页传入的残缺数据，在残缺数据上解析会得出错误线路。
  ///
  /// 传三个标量而不是 `PlaybackHistory`：`resolveHistoryTarget` 在纯逻辑层
  /// （`core/`），不得依赖 `services/storage.dart`。
  HistoryResumeTarget _resumeTarget(List<VodPlayLine> lines) {
    final history = _history;
    return resolveHistoryTarget(
      historyFlag: history?.flag ?? '',
      historyEpisodeId: history?.episodeId ?? '',
      historyEpisodeName: history?.episodeName ?? '',
      lines: lines,
    );
  }

  /// 首屏按钮文案（`docs/phase6/design/02` §3.1）。
  ///
  /// 只有「线路与集都对上」且还有续播位置才叫「继续播放」——两个条件都交给
  /// 已有实现判断：`matched` 由 [resolveHistoryTarget] 给出，续播位置由
  /// [AppState.resumePositionFor] 给出（它已把 `completed` 与「位置过短」
  /// 一起处理）。这里不重复实现其中任何一条，否则两处判定会漂移。
  ///
  /// `matched == false` 时**不**提前返回：`historyPlayLabel` 内部已经判过
  /// `matched` 并回落到 `fallback`，在这里再判一次就是重复判定——也正是
  /// §3.1 要避免的那种漂移。
  String _heroPlayLabel(List<VodPlayLine> lines, Vod vod) {
    final target = _resumeTarget(lines);
    final resume = widget.state.resumePositionFor(
      siteKey: widget.state.selectedSite?.key ?? '',
      vodId: vod.vodId,
      flag: target.flag,
      episodeId: _history?.episodeId,
    );
    return historyPlayLabel(target: target, resumePosition: resume);
  }

  /// 历史那一集在**渲染列表**里的下标（-1 = 无，`design/02` §6）。
  ///
  /// 为什么需要换算：`resolveHistoryTarget` 给的是**线路原始下标**，而卡片是按
  /// `ordered`（已套用 TMDB 元数据 + 已季度过滤 + 可能已倒序）渲染的，
  /// 两个下标在「多季线路」或「倒序」下并不相等。直接把原始下标交给
  /// [TmdbEpisodeStrip.recentIndex] 会标错集。
  ///
  /// 用集 **URL** 而不是集号做桥接：集号可能缺失或重复（`stillKey` 的注释里
  /// 已记过这个坑），URL 才是「同一集」的稳定身份。
  ///
  /// 三道守卫都不可省：
  /// 1. `matched` —— `matched == false` 涵盖「无历史」与「历史线路在但那一集
  ///    已消失」（§4.1），标出来会把用户引到一条没有那一集的线路上；
  /// 2. `rawLine.flag == target.flag` —— 只有历史命中的**那条线路**才标，
  ///    否则切到别的线路也会看到标记；
  /// 3. 下标越界 —— `lines` 与 `rawLine` 理论上同源，但越界时必须回落到
  ///    「无标记」而不是抛异常（详情刷新期间两者可能短暂不同步）。
  int _recentRenderedIndex(
    Vod vod,
    VodPlayLine rawLine,
    List<VodEpisode> ordered,
  ) {
    final lines = widget.state.playLinesOf(vod);
    final target = _resumeTarget(lines);
    if (!target.matched) return -1;
    if (rawLine.flag != target.flag) return -1;
    if (target.episodeIndex < 0 ||
        target.episodeIndex >= rawLine.episodes.length) {
      return -1;
    }
    final episode = rawLine.episodes[target.episodeIndex];
    for (var i = 0; i < ordered.length; i++) {
      if (identical(ordered[i], episode) || ordered[i].url == episode.url) {
        return i;
      }
    }
    return -1;
  }

  Vod? get _currentVod {
    final result = widget.state.detailResult;
    if (result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId) {
      return result.list.first;
    }
    return widget.vod;
  }

  Future<void> _play(Vod vod, VodPlayLine line, int episodeIndex) async {
    final episode = line.episodes[episodeIndex];
    final state = widget.state;
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: episode.url,
        flag: line.playbackFlag,
        vodId: vod.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '播放决策没有返回可用地址',
          detail: 'line=${line.flag} episode=${episode.name}',
        );
      }
      if (!mounted) return;
      // §15.2「继续播放」：进入播放器时从历史位置续播（无有效历史则为 null）。
      //
      // 必须同时给 `episodeName`：同步来的历史 `episode_id` 存的是安卓哈希
      // （`episodeUrl` 的 SHA-256），与这里的 `episode.url`（站点入口）不同源，
      // 只靠 `episodeId` 永远命不中 → 手动拉取的历史点开就从头开始。
      final resume = state.resumePositionFor(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
        flag: line.playbackFlag,
        episodeId: episode.url,
        episodeName: episode.name,
      );
      // TMDB 季度身份（`04` §8.1）：已确证季度时透传；未确证时只传 URL/集名。
      final tmdb = state.tmdb;
      final identity = TmdbPlaybackIdentity.of(
        identity: tmdb.identity,
        episode: episode,
        flagKey: tmdb.sourceLine?.flagKey ?? line.flag,
        seasonNumber: tmdb.hasMatch && tmdb.selectedSeason >= 0
            ? tmdb.selectedSeason
            : -1,
        episodeNumber: _tmdbEpisodeNumberOf(episode),
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              // 历史里存**站点入口目标**（`episode.url`），而不是这个解析后的
              // 可播地址（带时效签名，站点不认）。续播时要拿它回传站点重解析。
              episodeTarget: episode.url,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: vod.vodName,
              siteKey: state.selectedSite?.key ?? '',
              vodId: vod.vodId,
              vodName: vod.vodName,
              episodeName: episode.name,
              flag: line.flag,
              playbackFlag: line.playbackFlag,
              playLines: state.playLinesOf(vod),
              episodeIndex: episodeIndex,
              vodPic: vod.vodPic,
              startPosition: resume,
              // 外挂字幕（§10.3）与弹幕（§21 Phase 3）：播放结果 + 代理前 Header。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
              tmdb: identity.hasIdentity ? identity : null,
            ),
          ),
        ),
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.userMessage)));
    }
  }

  static int _tmdbEpisodeNumberOf(VodEpisode episode) {
    final raw = episode.extra['tmdb_episode_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // 只有「结果属于本页影片」才允许渲染（§8.3）。
    //
    // 详情结果是 AppState 上的全局字段，用户「返回列表 → 点另一部剧」时，前一个
    // 请求可能还在飞行（本机实测 3.9~7.1s），若直接取 `detailResult.list.first`，
    // 新页面会先套用上一部剧的线路与简介，点播即串剧。这里以 vod_id 判归属，
    // 不属于本页时退回列表页传入的条目（其线路可能已由列表数据携带）。
    final result = state.detailResult;
    final belongs =
        result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId;
    final vod = belongs ? result.list.first : widget.vod;
    final lines = state.playLinesOf(vod);
    // 详情到达后自动切到历史线路（`docs/phase6/design/02` §4、§4.1）。
    //
    // 为什么在 build 里而不是 initState：详情请求在页面挂载后才完成，
    // initState 时 lines 还是残缺的。
    //
    // **必须等 `belongs` 为真**（= 本页的详情结果已到达），不能只看
    // `lines.isNotEmpty`：后者在详情未到达时可能是**列表页传入条目的残缺线路**，
    // 在残缺集合上解析会得出错误线路（§2.1 第二级的"唯一命中"在集合变小时
    // 可能假唯一），而且 `_selectedLineFlag` 一旦写入就**永久锁死**
    // （下面 `isEmpty` 守卫会让真详情到达后不再重解析）。
    //
    // **只有 `matched == true` 才切**（`design/02` §4.1）：`matched == false`
    // 涵盖「无历史」「历史线路在但那一集已消失」两种情形，它们都不该改变
    // 用户的线路选择——切过去也没有那一集。
    if (belongs && lines.isNotEmpty) {
      final target = _resumeTarget(lines);
      // 只在「用户还没手动选过」时应用（`_selectedLineFlag` 为空）。
      // 用户手动切过线路后，历史不得把选择抢回去。
      if (target.matched && _selectedLineFlag.isEmpty) {
        _selectedLineFlag = target.flag;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          state.tmdb.selectLine(target.flag);
          unawaited(state.reloadTmdb());
        });
      }
    }
    final loading = state.detailPhase == LoadPhase.loading;
    final tmdb = state.tmdb;
    // 头部补位（`04` §3.2）：**仅补位不覆盖**来源已有字段。
    final display = tmdb.hasMatch ? tmdb.enrich(vod).vod : vod;
    // TMDB 展示模型（海报/背景/类型/时长/季集数/演职人员…）。
    final tmdbData = tmdb.detailData;
    // 头部数据：未匹配 TMDB 时回退到来源海报，保证头部不空白。
    //
    // 提成局部变量是因为**页面级背景**要用同一份。两处各算一次的话，
    // 回退分支可能得出不同结果（背景与头部的图不一致）。
    final headerData =
        tmdb.detailData ??
        TmdbDetailData(
          title: display.vodName,
          overview: display.vodContent,
          posterUrl: display.vodPic,
          backdropUrls: [
            if ((display.vodPic ?? '').isNotEmpty) display.vodPic!,
          ],
          rating: 0,
        );

    return Scaffold(
      // 头部是**全幅 hero**（用户反馈 2026-10-09：「详情页太简陋，背景海报也没有
      // 全屏显示」）：背景海报铺满整宽并延伸到 app bar 之下，app bar 自身透明，
      // 只把返回/收藏/刷新浮在背景上。内容区不再整体加 16 边距（那样 hero 两侧会
      // 露出底色，就没有「全屏」可言），改由正文各自留边。
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        // 顶部透明：hero 的背景海报能一直铺到屏幕最上边。
        backgroundColor: Colors.transparent,
        // 滚动到内容经过 app bar 下方时恢复不透明底色（用页面底色而非主题色
        // 调），否则标题会与正文文字叠在一起。
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        title: Text(vod.vodName),
        leading: IconButton(
          tooltip: '返回',
          onPressed: _closeDetail,
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            tooltip: state.isFavorite(kind: 'vod', targetId: vod.vodId)
                ? '取消收藏'
                : '收藏该影片',
            onPressed: () => state.toggleFavorite(
              kind: 'vod',
              targetId: vod.vodId,
              title: vod.vodName,
              subtitle: vod.vodRemarks,
            ),
            icon: Icon(
              state.isFavorite(kind: 'vod', targetId: vod.vodId)
                  ? Icons.bookmark
                  : Icons.bookmark_border,
            ),
          ),
          IconButton(
            tooltip: '刷新详情',
            onPressed: () => state.loadDetail(widget.vod),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          // 页面级**固定**背景（用户反馈 2026-10-13：「后续内容也应该显示在图片上」）。
          //
          // 为什么放在这里而不是头部里：`Positioned.fill` **脱离滚动**，所以
          // 整页内容都浮在图上；图片不会随内容滚走、下半页也不会变回纯色。
          // 头部因此不再自己画图（`paintImage: false`）。
          Positioned.fill(
            child: TmdbDetailBackdrop(
              urls: headerData.backdropUrls,
              fallbackUrl: headerData.posterUrl,
            ),
          ),
          if (loading && lines.isEmpty)
            const Positioned.fill(child: Center(child: LoadingBlock()))
          else
            ListView(
              padding: EdgeInsets.zero,
              children: [
                // 详情错误只在「确实是在拉本页详情且没有可用线路」时提示，
                // 避免上一个条目的失败信息干扰当前页面（§8.3、§8.4）。
                // 内容已延伸到 app bar 之下，因此这条提示要让出 app bar 的高度，
                // 否则会被悬浮的返回/收藏图标压住。
                if (state.detailError != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
                      16,
                      8,
                    ),
                    child: ErrorBanner(
                      error: state.detailError!,
                      onDismiss: state.clearDetailError,
                    ),
                  ),
                // 动态背景头部（`04` §3.1 ①）：用 TMDB 海报/剧照当背景，
                // 未匹配时回退到来源海报，保证头部不空白。
                // 高度由组件按视口自适应（见 TmdbDetailHeader.resolveHeight）。
                TmdbDetailHeader(
                  // 图片由页面级背景负责（见本 body 的 Stack），头部只画内容。
                  paintImage: false,
                  data: headerData,
                  heroOverview: display.vodContent ?? tmdbData?.overview,
                  heroActions: lines.isEmpty
                      ? null
                      : Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('detail-hero-play'),
                              onPressed: () => _play(
                                vod,
                                _activeLine(lines),
                                // 历史命中的那一集（`design/02` §3.2）。
                                // `matched == false` 时它本来就是 0，
                                // 正是「播放第一集」该有的行为，无需额外分支。
                                //
                                // 这里用的是**原始下标**（`VodPlayLine.episodes`
                                // 的下标），而渲染下标经过季度过滤与倒序——
                                // `_play` 要的正是原始下标（§3.3）。
                                _resumeTarget(lines).episodeIndex,
                              ),
                              icon: const Icon(Icons.play_arrow),
                              label: Text(_heroPlayLabel(lines, vod)),
                            ),
                            if ((display.vodContent ?? tmdbData?.overview ?? '')
                                    .trim()
                                    .length >
                                220)
                              TextButton.icon(
                                key: const ValueKey('detail-hero-overview'),
                                onPressed: () => _openOverviewDialog(
                                  (display.vodContent ??
                                          tmdbData?.overview ??
                                          '')
                                      .trim(),
                                ),
                                icon: const Icon(Icons.subject_outlined),
                                label: const Text('查看简介'),
                              ),
                          ],
                        ),
                ),
                // 正文统一留 16 边距（hero 不加，才能左右铺满）。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // TMDB 状态条原在 hero 之上（会被悬浮 app bar 遮住），
                      // 改到 hero 下方：既不与图标重叠，也更靠近正文。
                      TmdbStatusBar(
                        state: tmdb,
                        onConfigure: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TmdbSettingsPage(state: state),
                          ),
                        ),
                        onMatch: _openMatchDialog,
                        onRematch: _openMatchDialog,
                        onSelectSeason: _openSeasonDialog,
                        onRetry: () => state.reloadTmdb(),
                      ),
                      const SizedBox(height: 12),
                      // 信息表（`04` §3.1 ①）：对齐上游 `site/year/area/type/
                      // director/actor` 的元信息行。**来源字段优先**，缺失处用 TMDB
                      // 补位值（§3.2「仅补位不覆盖」），因此这里直接读补位后的 `display`
                      // 与 `tmdbData`。
                      TmdbInfoTable(
                        rows: [
                          // **只留 hero 没说的字段。**
                          //
                          // 原来 11 行里 8 行与 hero 标签行**逐字重复**
                          // （类型/地区/年份/时长/季集/状态/评分），导演在 hero 简介里
                          // 已有，演员在下方「演职人员」区块里还带头像。
                          // 整块等于把同样的信息让人读两遍（用户反馈 2026-10-13）。
                          //
                          // 为什么不按原计划"并进 hero 标签行"：`_MetaChips` 有
                          // **7 个上限**（`maxChips: 7`），而 hero 现在正好是 7 个
                          // （TMDB 8.0 / 2026 / 47分钟 / 1季·30集 / 剧情 / China /
                          // Returning Series）——再塞两条会把已有的挤掉，反而更差。
                          //
                          // `TmdbInfoTable` 会跳过空值行，所以字段缺失时这块整块消失。
                          ('备注', display.vodRemarks),
                          ('语言', tmdbData?.languages.join(' / ')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // 季度选择器（`04` §4.1）：仅 tv 且已匹配时渲染。
                      TmdbSeasonSelector(
                        state: tmdb,
                        onChanged: (season) {
                          tmdb.selectSeason(season);
                          unawaited(
                            tmdb.loadEpisodes(generation: tmdb.generation),
                          );
                        },
                        onSelectManual: _openSeasonDialog,
                      ),
                      // 纯 TMDB 详情页入口（`04` §6.1）。
                      if (tmdb.hasMatch && tmdb.identity != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('tmdb-open-detail'),
                            onPressed: () => _openTmdbDetail(tmdb.identity!),
                            icon: const Icon(Icons.movie_outlined, size: 18),
                            label: const Text('在 TMDB 中查看'),
                          ),
                        ),
                      const Divider(height: 32),
                      if (loading && lines.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: LoadingBlock(),
                        )
                      else if (lines.isEmpty)
                        Text(
                          state.detailError?.userMessage ??
                              '该影片没有可播放的剧集（vod_play_url 为空）。',
                        ),
                      if (lines.isNotEmpty) ...[
                        // 线路选择（`04` §3.1 ④）：点击即切换，剧集卡片随之切换。
                        // 对齐上游 `@id/flag` —— 上游也只渲染**当前线路**的选集区。
                        TmdbLineSelector(
                          lines: lines,
                          selectedFlag: _activeLine(lines).flag,
                          // 「最近播放」标记（`design/02` §5）：只有
                          // `matched == true` 才标——`matched == false` 涵盖
                          // 「无历史」与「历史线路在但那一集已消失」两种情形，
                          // 后者标出来会把用户引到一条没有那一集的线路上。
                          recentFlag: _resumeTarget(lines).matched
                              ? _resumeTarget(lines).flag
                              : '',
                          episodeCounts: _episodeCountsByLine(lines),
                          onChanged: (line) => _selectLine(line, lines),
                        ),
                        _buildEpisodes(context, vod, lines),
                      ],
                      // ⑥⑦⑧⑨ TMDB 附加区块（`04` §3.1）：失败时整块隐藏（不显示空态占位）。
                      //
                      // folder 展开**也要**渲染：被点的 folder 条目本身就是一部作品
                      // （名称/海报/集数备注齐备），只是它没有线路而已（用户反馈
                      // 「桥接站点还是没有 tmdb 详情页」）。信息表缺失字段由
                      // `TmdbInfoTable` 自行跳过空值行。
                      ..._buildTmdbBlocks(context, tmdb),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 线路已经在详情加载阶段展开，详情页只负责标准线路渲染。

  /// 剧照墙 / 演职人员 / 相关推荐 / 相关视频（`04` §3.1 ⑥–⑨）。
  ///
  /// 全部**可点击**（用户反馈：之前点击无效）：
  /// - 剧照 → 大图查看器（可翻页）；
  /// - 演职人员 → 人物页（简介/照片/作品）；
  /// - 相关推荐 → 该作品的 TMDB 详情页；
  /// - 相关视频 → 浏览器打开 / 复制链接。
  List<Widget> _buildTmdbBlocks(BuildContext context, TmdbState tmdb) {
    final data = tmdb.detailData;
    if (data == null) return const [];
    return [
      const Divider(height: 32),
      TmdbDetailSections(
        data: data,
        recommendations: tmdb.recommendations,
        videos: tmdb.videos,
        onPersonTap: _openPerson,
        onRecommendationTap: _openItemDetail,
        onOpenVideo: widget.state.openExternalUrl,
        onCopyVideo: copyToClipboard,
      ),
    ];
  }

  /// 打开人物页（演职人员点击）。
  void _openPerson(TmdbPerson person) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbPersonPage(
          service: widget.state.tmdbService,
          person: person,
          onOpenItem: _openItemDetail,
        ),
      ),
    );
  }

  /// 打开某个 TMDB 作品详情（相关推荐 / 人物作品点击）。
  void _openItemDetail(TmdbItem item) {
    final identity = item.identity;
    if (identity == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: widget.state.tmdbService,
          identity: identity,
          initialItem: item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: widget.state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
          onOpenVideo: widget.state.openExternalUrl,
          onCopyVideo: copyToClipboard,
        ),
      ),
    );
  }

  /// 当前线路（未选定时取第一条）。
  ///
  /// 必须先于任何渲染使用：线路决定「用哪条线路的集 + 哪个季度解析结果」。
  VodPlayLine _activeLine(List<VodPlayLine> lines) {
    for (final line in lines) {
      if (line.flag == _selectedLineFlag) return line;
    }
    return lines.first;
  }

  /// 切换线路（`04` §4.3：切换线路必须重新解析该线路的可播放季度）。
  ///
  /// 必须把**当前季度作为意图**传给状态层：新线路可能没有当前季度的集
  /// （例如「线路一 S1+S2」切到「只有 S2 的线路二」），不给意图就会回落到
  /// 默认季（S1），线路二在 S1 下一集都没有 → 剧集区空白。
  void _selectLine(VodPlayLine line, List<VodPlayLine> lines) {
    if (line.flag == _activeLine(lines).flag) return;
    final tmdb = widget.state.tmdb;
    final preferred = tmdb.selectedSeason;
    setState(() => _selectedLineFlag = line.flag);
    tmdb.selectLine(line.flag, preferredSeason: preferred);
    unawaited(widget.state.reloadTmdb());
  }

  /// 每条线路在当前季度下**渲染**的集数（供线路条展示）。
  ///
  /// 只有当前线路能拿到 TMDB 季度解析结果（季度是线路级的，`02` §2.2），
  /// 因此其余线路只做**来源季度信号**过滤，不套用当前线路的季度。
  Map<String, int> _episodeCountsByLine(List<VodPlayLine> lines) {
    final active = _activeLine(lines);
    final result = <String, int>{};
    for (final line in lines) {
      final isActive = line.flag == active.flag;
      if (isActive) {
        result[line.flag] = _renderEpisodes(line, active: true).length;
        continue;
      }
      result[line.flag] = _renderEpisodes(line, active: false).length;
    }
    return result;
  }

  /// 某条线路在「当前季度」下要渲染的集（`04` §4.2）。
  ///
  /// - 当前线路：先应用 TMDB 剧集元数据，再按可播放季度过滤；
  /// - 其他线路：不套用当前季度的元数据与过滤（避免跨线路串集），
  ///   只保留来源集名自带的季度信号过滤。
  List<VodEpisode> _renderEpisodes(
    VodPlayLine rawLine, {
    required bool active,
  }) {
    final tmdb = widget.state.tmdb;
    if (!active) {
      final selected = tmdb.selectedSeason;
      if (selected < 0) return rawLine.episodes;
      return TmdbEpisodeRenderPolicy.filter(
        episodes: rawLine.episodes,
        availableSeasons: const [],
        selectedSeason: selected,
        seasonOf: _seasonOfEpisode,
      );
    }
    final line = tmdb.applyEpisodesToLine(rawLine).line;
    return TmdbEpisodeRenderPolicy.filter(
      episodes: line.episodes,
      availableSeasons: tmdb.availableSeasons,
      selectedSeason: tmdb.selectedSeason,
      seasonOf: _seasonOfEpisode,
    );
  }

  /// 渲染当前线路的剧集区（区块头 + 剧集卡片）。
  Widget _buildEpisodes(
    BuildContext context,
    Vod vod,
    List<VodPlayLine> lines,
  ) {
    final state = widget.state;
    final tmdb = state.tmdb;
    final rawLine = _activeLine(lines);
    final line = tmdb.applyEpisodesToLine(rawLine).line;
    final episodes = _renderEpisodes(rawLine, active: true);
    final ordered = _episodesReversed ? episodes.reversed.toList() : episodes;

    // 切季 → 区间回到该季第一集所在区间（`docs/phase6/design/03` §5.1）。
    //
    // 用季度序号检测而不是回调链：`build` 会被多次通知触发，回调容易
    // 在时序上漏掉或多触发。
    if (_lastSeasonEpoch != tmdb.seasonEpoch) {
      _lastSeasonEpoch = tmdb.seasonEpoch;
      _rangeIndex = 0;
      _manualRange = false;
    }

    // 区间分组（`docs/phase6/design/03` §4.1）。
    //
    // 未手动选过时，区间跟随「用户关注的那一集」：优先历史命中的集，
    // 否则第 0 集——否则用户从历史续播进来会看到第 1 页而当前集在第 4 页。
    final ranges = _rangeLabels(
      ordered,
      EpisodeRangePolicy.build(
        ordered.length,
        _manualRange
            ? _rangeIndex * EpisodeRangePolicy.groupSize(ordered.length)
            : _focusIndex(vod, rawLine, ordered),
        _episodesReversed,
      ),
    );
    final rangeIndex = _manualRange
        ? _rangeIndex.clamp(0, ranges.length - 1)
        : EpisodeRangePolicy.selectedPosition(ranges);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TmdbEpisodeHeader(
          episodeCount: episodes.length,
          reversed: _episodesReversed,
          gridMode: _episodeGridMode,
          lineName: rawLine.displayName,
          onToggleReversed: () =>
              setState(() => _episodesReversed = !_episodesReversed),
          onToggleGridMode: () =>
              setState(() => _episodeGridMode = !_episodeGridMode),
        ),
        // 剧集海报卡片：本线路**唯一**的选集入口（用户反馈 2026-10-08：
        // 有卡片时不再渲染文字版集按钮，二者取其一）。
        // 卡片数量恒等于本线路渲染的集数；未匹配 TMDB 时用来源剧照/海报兑底，
        // 保证「每集都有画面」。
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-${rawLine.flag}'),
          cards: tmdb.episodeCardsForEpisodes(
            ordered,
            seasonNumber: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
            includeMetadata: true,
          ),
          keyPrefix: 'tmdb-episode-card-${rawLine.flag}',
          actionLabel: '播放',
          cardWidth: _episodeCardWidth(context, episodes.length),
          gridMode: _episodeGridMode,
          recentIndex: _recentRenderedIndex(vod, rawLine, ordered),
          ranges: ranges,
          rangeIndex: rangeIndex,
          onRangeChanged: (index) => setState(() {
            _rangeIndex = index;
            _manualRange = true;
          }),
          onTap: (index, _) =>
              _playEpisodeAt(vod, rawLine, line, ordered, index),
        ),
      ],
    );
  }

  /// 自动跟随的焦点集在**渲染列表**里的下标。
  ///
  /// 优先「历史命中的那一集」，否则第 0 集。
  int _focusIndex(Vod vod, VodPlayLine rawLine, List<VodEpisode> ordered) {
    if (ordered.isEmpty) return 0;
    final recent = _recentRenderedIndex(vod, rawLine, ordered);
    return recent < 0 ? 0 : recent;
  }

  /// 用**真实集号**修正区间标签（`docs/phase6/design/03` §4.2）。
  ///
  /// 集号可能不连续（缺号、重复号），直接用列表下标会误导
  /// （对齐上游 `buildCardEpisodeRanges` 的标签修正）。
  List<EpisodeRange> _rangeLabels(
    List<VodEpisode> ordered,
    List<EpisodeRange> ranges,
  ) {
    final corrected = <EpisodeRange>[];
    for (final range in ranges) {
      final slice = EpisodeRangePolicy.slice(ordered, range);
      if (slice.isEmpty) {
        corrected.add(range);
        continue;
      }
      final first = _episodeNumberOr(slice.first, ordered, range.start + 1);
      final last = _episodeNumberOr(slice.last, ordered, range.end);
      corrected.add(
        EpisodeRange(
          label: first == last ? '$first' : '$first-$last',
          start: range.start,
          end: range.end,
          selected: range.selected,
        ),
      );
    }
    return corrected;
  }

  /// TMDB 富集的集号；取不到时退回 [fallback]（列表下标 + 1）。
  ///
  /// 复用既有的 [_tmdbEpisodeNumberOf]（它取不到时返回 -1），
  /// 不另写一份重复实现（对齐上游 `numbers.getOrDefault(first, start + 1)`）。
  int _episodeNumberOr(
    VodEpisode episode,
    List<VodEpisode> ordered,
    int fallback,
  ) {
    final number = _tmdbEpisodeNumberOf(episode);
    return number > 0 ? number : fallback;
  }

  /// 按**渲染下标**播放（卡片下标 → 线路原始下标）。
  void _playEpisodeAt(
    Vod vod,
    VodPlayLine rawLine,
    VodPlayLine line,
    List<VodEpisode> episodes,
    int index,
  ) {
    if (index < 0 || index >= episodes.length) return;
    final episode = episodes[index];
    // 播放必须用**线路原始下标**（TMDB 只丰富展示，不改变播放事实源）。
    final rawIndex = line.episodes.indexWhere(
      (candidate) =>
          identical(candidate, episode) || candidate.url == episode.url,
    );
    _play(vod, rawLine, rawIndex < 0 ? index : rawIndex);
  }

  /// 剧集卡片宽度（`04` §4.4 列数策略的卡片版）。
  ///
  /// 集数多的线路把卡做窄，使一行能看到更多集，减少横向滚动；集数少时保持
  /// 大卡以突出剧照。窗口很窄时兜底到最小宽度，不得为负或过小。
  static double _episodeCardWidth(BuildContext context, int episodeCount) {
    final width = MediaQuery.sizeOf(context).width;
    final targetColumns = switch (episodeCount) {
      <= 8 => 5,
      <= 20 => 7,
      _ => 9,
    };
    final available = width - 32 - (targetColumns - 1) * 10;
    final raw = available / targetColumns;
    return raw.clamp(150.0, 300.0);
  }

  /// 剧集所在季度。
  ///
  /// 优先取 TMDB 富集写入的 `tmdb_season_number`；否则回退到**来源集名**里的
  /// 季度信号（`第 N 季` / `SxxExx`）。
  ///
  /// 为什么必须回退：富集只为**当前选中季度**写 `tmdb_season_number`，其余
  /// 季度的集不会被标记。若只看 `extra`，多季线路的季度过滤就会失效
  /// （所有集都被当成「未分类」而保留，选集数永不缩小）。
  /// 来源集名是**事实源**（§27 原则 1），用它分类不引入任何猜测。
  static int _seasonOfEpisode(VodEpisode episode) {
    final raw = episode.extra['tmdb_season_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return sourceSeasonNumber(episode.name);
  }

  /// 打开纯 TMDB 详情页（`04` §6）。
  ///
  /// 该页面**没有播放按钮**；剧集卡片点击后跳搜索页并带入标题与身份提示。
  Future<void> _openTmdbDetail(TmdbIdentity identity) async {
    final state = widget.state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: state.tmdbService,
          identity: identity,
          initialItem: state.tmdb.item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 简介：默认 4 行 + 「展开 / 收起」（`04` §11 长文本要求）。
class _ExpandableOverview extends StatefulWidget {
  const _ExpandableOverview({required this.text});

  final String text;

  @override
  State<_ExpandableOverview> createState() => _ExpandableOverviewState();
}

class _ExpandableOverviewState extends State<_ExpandableOverview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('tmdb-overview'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          style: theme.textTheme.bodyMedium,
          maxLines: _expanded ? null : 4,
          overflow: _expanded ? null : TextOverflow.ellipsis,
        ),
        if (widget.text.length > 120)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('tmdb-overview-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起' : '展开'),
            ),
          ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return EmptyState(title: title, message: message);
  }
}

/// 站点运行时未支持时的明确提示（§8.1 “不得显示空列表”）。
class _UnsupportedSiteHint extends StatelessWidget {
  const _UnsupportedSiteHint({required this.site, required this.availability});

  final Site site;
  final SiteAvailability availability;

  @override
  Widget build(BuildContext context) {
    return _EmptyHint(
      title: '站点运行时未安装或不支持',
      message:
          '站点「${site.name}」需要 ${availability.runtimeName} 运行时'
          '${availability.stage == null ? "" : "（计划阶段：${availability.stage}）"}。\n'
          '${availability.reason ?? ""}\n'
          '请在站点列表中选择其他可运行站点。',
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        // 通知是**信息**，不是警报：不铺满色块，只用一层极淡的底 + 发丝边，
        // 让它在层级上明显轻于错误横幅（后者用 errorContainer 实底）。
        // 原实现用 `secondaryContainer` 实底满宽，与错误横幅同等重量，
        // 两条叠在一起时读者分不清哪条更要紧。
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: AppRadius.smAll,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          // 用收紧的 IconButton 而不是默认尺寸：默认最小点击区会把这条
          // 信息条撑到 60px 以上，与"轻量通知"的意图相反。
          // 保留 IconButton 类型：测试按类型统计 InkWell / GestureDetector，
          // 换成它们会引入无谓风险。
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 15),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// 与 `package:collection` 的 `firstOrNull` 等价的本地实现，避免为此新增依赖。
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull() {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
