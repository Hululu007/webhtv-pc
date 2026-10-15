/// TMDB 详情页视图（`docs/phase4/design/04` §3、§6、§11）。
///
/// 这是**站点详情页**与**纯 TMDB 详情页**共用的渲染层：
///
/// ```text
/// ┌ 动态背景（剧集海报/剧照轮播 + 渐变遮罩）────────────────────┐
/// │ [海报] 标题 / 原名 / 标语                                    │
/// │        评分 · 年份 · 时长 · 季集数 · 类型 · 地区              │
/// │        导演：…                                               │
/// │        简介（折叠 + 展开）                                    │
/// ├ 季度（海报卡片 + 集数）──────────────────────────────────────┤
/// ├ 剧集（每集一张海报卡片：剧照 + 标题 + 播出日期）───────────────┤
/// ├ 剧照墙（点击 → 大图查看器，可翻页）───────────────────────────┤
/// ├ 演职人员（点击 → 人物页：简介 / 照片 / 作品）──────────────────┤
/// ├ 相关推荐（点击 → 进入该作品详情）─────────────────────────────┤
/// └ 相关视频（浏览器打开 / 复制链接）─────────────────────────────┘
/// ```
///
/// 关键约束：
/// - 纯 TMDB 详情页的剧集卡片**不得**显示为可播放（`04` §6.2）；
///   由调用方通过 [TmdbDetailView.episodeActionLabel] 与 [onEpisodeTap] 决定行为；
/// - 失败隔离：任一区块为空时整块隐藏，不留空态占位（`04` §3.4）；
/// - 深色模式使用 `Theme.of(context)` 语义色，不硬编码颜色（`04` §11）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../core/app_error.dart';
import '../core/person_work_filters.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/protocol.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import 'app.dart' show PosterImage;
import 'common.dart';
import 'tokens.dart';
import 'tmdb_widgets.dart' show TmdbLoadPhase, TmdbVideoTile;

/// 动态背景轮播（`04` §3.1：用剧集海报/剧照当动态背景）。
///
/// 节奏与上游 `TmdbHeaderView` 一致（5 秒一张）。**只有一张图时不启动轮播**，
/// 且仅在「当前路由 + TickerMode 启用」时运行——页面被覆盖或不可见时停止，
/// 既不浪费解码，也避免测试里的无限帧调度。
class TmdbBackdropSlideshow extends StatefulWidget {
  const TmdbBackdropSlideshow({
    super.key,
    required this.urls,
    this.height = 320,
    this.contentBand,
    this.paintImage = true,
    this.scrim = TmdbBackdropScrim.hero,
    this.interval = TmdbBackdropRotation.interval,
    this.fallbackUrl,
    this.child,
  });

  final List<String> urls;

  /// **图片框**的高度。
  ///
  /// 取整个视口高度（用户反馈 2026-10-13：「我要的是全屏」）。这不只是观感问题，
  /// 它直接决定原图能显示多大：`BoxFit.contain` 下图片尺寸由**框的短边**决定——
  /// 427px 高、1312 宽的框（约 3.07:1）里，16:9 的原图只能按高度适配，
  /// 结果只有 759px 宽（两侧各留 276px 空白）；换成整屏 1312x791（约 1.66:1）
  /// 才能按宽度适配，得到 **1312x738 的完整原图、零裁切、几乎不放大**。
  final double height;

  /// **内容带**的高度（标题/简介/按钮所占的那一块），默认与 [height] 相同。
  ///
  /// 为什么与图片框分开：内容不能跟着图片一起变高。
  /// 早先为了让「简介、播放入口、线路更早进入首屏」，内容带被定在视口约 54%
  /// （见 [TmdbDetailHeader.resolveHeight]）——那是**内容**的诉求，与图片该多大无关。
  /// 混在一起时只能二选一：要么图片被裁，要么内容被推下去。拆开之后两者各自成立：
  /// 图片铺满整屏，内容仍待在原来的高度位置（`phase4_tmdb_detail_hero_test` 锁着它）。
  final double? contentBand;

  /// 是否绘制背景图本身（图片、遮罩、轮播指示点）。
  ///
  /// 传 `false` 用于**页面级固定背景**：那种场景下图片由页面底层的
  /// [TmdbDetailPageBackdrop] 负责，头部只负责内容。两处都画会重复解码，
  /// 而且两张同图不同框比会在交界处错位。
  final bool paintImage;

  /// 遮罩力度（见 [TmdbBackdropScrim]）。
  final TmdbBackdropScrim scrim;

  final Duration interval;

  /// 无背景图时使用的兜底图（通常是海报）。
  final String? fallbackUrl;

  /// 覆盖在背景之上的内容（标题、简介等）。
  final Widget? child;

  @override
  State<TmdbBackdropSlideshow> createState() => _TmdbBackdropSlideshowState();
}

class _TmdbBackdropSlideshowState extends State<TmdbBackdropSlideshow> {
  Timer? _timer;
  int _index = 0;

  List<String> get _effective {
    if (widget.urls.isNotEmpty) return widget.urls;
    final fallback = widget.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) return [fallback];
    return const [];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(TmdbBackdropSlideshow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urls != widget.urls) {
      _index = 0;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _syncTimer() {
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? true;
    // `TickerMode.valuesOf` 同时给出 enabled 与 forceFrames（`of` 已废弃）。
    final animationsEnabled = TickerMode.valuesOf(context).enabled;
    final shouldRun =
        TmdbBackdropRotation.shouldRotate(_effective.length) &&
        isCurrent &&
        animationsEnabled;
    if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      final urls = _effective;
      if (!TmdbBackdropRotation.shouldRotate(urls.length)) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      setState(() => _index = TmdbBackdropRotation.next(_index, urls.length));
    });
  }

  /// 图片框比内容带高出来的那一段（≥0）。
  double get _bandOffset {
    final band = widget.contentBand ?? widget.height;
    final offset = widget.height - band;
    return offset > 0 ? offset : 0;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urls = _effective;
    final index = TmdbBackdropRotation.clamp(_index, urls.length);
    final current = index < 0 ? null : urls[index];
    return SizedBox(
      // 键名如实反映"这块是什么"：画图时它是**背景轮播**；只画内容时
      // （页面级固定背景接管了图片）它是**头部内容块**。
      //
      // 必须分开：两种用法会同时出现在同一棵树上（页面背景 + 头部），
      // 共用一个 key 会让 `findsOneWidget` / `getRect` 直接失败。
      key: ValueKey(
        widget.paintImage ? 'tmdb-backdrop-slideshow' : 'tmdb-detail-hero',
      ),
      height: widget.height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景图：切换时淡入淡出（对齐上游「加载完成后切换」）。
          //
          // 必须用 `SizedBox.expand` 包住：`AnimatedSwitcher` 以**宽松约束**
          // 布局子节点，`Image.network` 在宽高均为 null 时会退回图片固有尺寸
          // （实测 160x160 的小方块居中，背景不铺满）。
          if (widget.paintImage)
            AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: current == null
                ? SizedBox.expand(
                    key: const ValueKey('tmdb-backdrop-empty'),
                    // 无背景图时用**页面底色**而不是 `surfaceContainerHighest`：
                    // 后者会在头部留一大块比页面亮得多的灰底（用户反馈
                    // 「无效的背景色区域太丑」）。页面底色下直接与内容融为一体。
                    child: ColoredBox(color: theme.colorScheme.surface),
                  )
                : SizedBox.expand(
                    key: ValueKey('tmdb-backdrop-$index'),
                    // V1（用户选型 2026-10-13）：`cover` 铺满 + 渐变遮罩。
                    //
                    // 为什么回到单层 `cover`，而不是"模糊垫底 + contain 主体"：
                    // 那个方案即使把色洗修对，锐利图与背景**缩放比不同**，
                    // 交界处就必然有一道可见的竖直分界——几何上消不掉。
                    // 而 `cover` 永远"看起来是有意的"：背景图被裁边是照片式的
                    // 自然结果，Emby / Jellyfin / Netflix 都这么做。
                    //
                    // 当初"裁切很丑"的真正原因是**框太扁**：hero 只有 427px 高
                    // （3.07:1），16:9 素材被迫纵向裁掉约 42%，把人的头顶从脸中间
                    // 切掉。现在图片框是**整个视口**（见 [TmdbBackdropSlideshow.height]），
                    // 用户的 2.35:1 窗口下只裁约 24%、16:9 窗口下只裁约 7%。
                    // 同一个 `cover`，框比不同，观感完全不同。
                    child: PosterImage(url: current, fit: BoxFit.cover),
                  ),
          ),
          // 渐变遮罩：保证文字在任何图片上都可读（不依赖图片亮度）。
          //
          // 上半部刻意保留较低不透明度（0.42）：用户要求「用剧集海报/剧照当动态
          // 背景」，遮罩太厚就把背景彻底洗成一片纯色，等于没有背景。
          // 下半部压到接近不透明：hero 改成**满屏**后，标题/海报落在屏幕底部，
          // 那里必须够暗才能保证白字可读。
          if (widget.paintImage)
            DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // 两种力度见 [TmdbBackdropScrim]：头部要压到不透明保证标题可读；
                // 页面级背景必须**轻且大体均匀**，否则正文滚到下半屏时图片就没了。
                colors: widget.scrim == TmdbBackdropScrim.hero
                    ? [
                        theme.colorScheme.surface.withValues(alpha: 0.42),
                        theme.colorScheme.surface.withValues(alpha: 0.40),
                        theme.colorScheme.surface.withValues(alpha: 0.78),
                        theme.colorScheme.surface,
                      ]
                    : [
                        theme.colorScheme.surface.withValues(alpha: 0.62),
                        theme.colorScheme.surface.withValues(alpha: 0.66),
                        theme.colorScheme.surface.withValues(alpha: 0.74),
                        theme.colorScheme.surface.withValues(alpha: 0.84),
                      ],
                stops: const [0, 0.45, 0.78, 1],
              ),
            ),
          ),
          if (widget.child != null)
            Padding(
              // 内容贴在**内容带**的底部，而不是图片框的底部。
              //
              // 图片框现在是整屏高，内容带仍是约 54% 视口；两者之差就是这段底部
              // 内边距——内容因此停在原来的高度，图片在它下面继续铺满整屏
              // （用户要的「全屏」），且不影响「简介/播放入口更早可见」那条既有结论。
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                44 + _bandOffset,
              ),
              // 内容贴底对齐：动态背景在上方露出更多画面，
              // 标题/海报靠近信息区，视觉上不会出现「背景里飘着一小块内容」。
              child: Align(
                alignment: Alignment.bottomLeft,
                child: widget.child,
              ),
            ),
            // 指示点放在**图片框底部**，不是内容带底部。
            //
            // 原来放在内容带底部（`_bandOffset + 12`）＝视口约 54% 处，
            // 也就是**屏幕正中间**——用户反馈「跑马灯的小点点显示在中间区域
            // 不好看」（2026-10-13）。图片框现在铺满整屏，底部是纯图片区，
            // 指示点落在那儿才是常规位置。
            if (widget.paintImage &&
                TmdbBackdropRotation.shouldRotate(urls.length))
              Positioned(
                right: 20,
                bottom: 16,
                top: null,
                child: Row(
                  key: const ValueKey('tmdb-backdrop-dots'),
                  children: [
                    for (var i = 0; i < urls.length; i++)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(left: 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == index
                              ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.3,
                              ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 背景遮罩力度。
enum TmdbBackdropScrim {
  /// 头部背景：底部要压到接近不透明，保证标题/简介在任意图上都读得清。
  hero,

  /// 页面级固定背景：**整页内容都浮在图上**，遮罩必须轻且大体均匀。
  ///
  /// 用 [hero] 的重遮罩会把下半屏压成不透明，正文滚到那里图片就消失了——
  /// 实测正是如此（2026-10-13 第一次接页面级背景时，图片只在屏幕顶部约 20%
  /// 可见，用户要的「后续内容也显示在图片上」等于没做到）。
  page,
}

/// 详情页的**页面级固定背景**：整页内容都浮在它上面。
///
/// 为什么单独一个组件（用户反馈 2026-10-13：「后续内容也应该显示在图片上」）：
/// 背景原先长在头部里，于是它的高度＝头部的高度，图片只覆盖首屏；往下滚动，
/// 正文就落回纯色页面底色，像是"图片没铺完"。
/// 这里由调用方放进 `Stack` 的 `Positioned.fill` ——**脱离滚动**，
/// 因此图片固定不动，正文在它上面滚过去。
///
/// 尺寸取整个视口：`Positioned.fill` 给的是紧约束，但
/// [TmdbBackdropSlideshow] 需要一个显式高度来决定内容带位置，所以这里传视口高。
class TmdbDetailBackdrop extends StatelessWidget {
  const TmdbDetailBackdrop({
    super.key,
    required this.urls,
    this.fallbackUrl,
  });

  final List<String> urls;

  /// 无背景图时的兜底（通常是海报）。
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) => TmdbBackdropSlideshow(
    urls: urls,
    fallbackUrl: fallbackUrl,
    height: MediaQuery.sizeOf(context).height,
    scrim: TmdbBackdropScrim.page,
  );
}

/// 详情页头部：动态背景（剧集海报/剧照轮播）+ 标题/评分/导演/简介。
///
/// 站点详情页与纯 TMDB 详情页共用；[statusBar] 用于插入站点页的 TMDB 6 态状态条。
class TmdbDetailHeader extends StatelessWidget {
  const TmdbDetailHeader({
    super.key,
    required this.data,
    this.statusBar,
    this.metadataBadge,
    this.height,
    this.heroOverview,
    this.heroActions,
    this.paintImage = true,
  });

  final TmdbDetailData data;
  final Widget? statusBar;
  final String? metadataBadge;

  /// 站点详情页可把来源简介提升到首屏；纯 TMDB 详情页保持旧布局。
  final String? heroOverview;

  /// 首屏主动作（例如“播放第一集”）。
  final Widget? heroActions;

  /// 是否由本头部绘制背景图，默认 `true`。
  ///
  /// 传 `false` 用于**页面级固定背景**（见 [TmdbDetailBackdrop]）：那时图片由页面
  /// 底层负责，头部只留内容。两处都画会重复解码，且同图不同框比会在交界处错位。
  final bool paintImage;

  /// 背景高度；为 `null` 时按视口自适应（见 [resolveHeight]）。
  final double? height;

  /// **内容带**的高度：标题/简介/按钮所占的那一块（**仅按视口**）。
  ///
  /// 主流媒体库详情页把内容控制在首屏约一半，简介和播放入口可见，
  /// 线路/分集不必被推到第二屏之后（用户反馈 2026-10-10 之后的既有结论，
  /// `phase4_tmdb_detail_hero_test` 锁着）。
  ///
  /// **它不再是图片框的高度。** 早先二者是同一个值，于是「内容要多早出现」与
  /// 「图片能显示多大」被迫二选一：内容带定在 54% 视口（1312x427 ≈ 3.07:1）时，
  /// 16:9 的原图在 `BoxFit.contain` 下只能按高度适配、降成 759px 宽，
  /// 用 `cover` 则要纵向裁掉约 42%（用户反馈 2026-10-13：「上面部分被截掉了」）。
  /// 现在图片框取整屏（见 [TmdbBackdropSlideshow.height]），内容带保持此值，
  /// 两条诉求各自成立。
  ///
  /// 注意：本函数**不知道父级约束**。若调用方把 header 放进有界高度（如
  /// `SizedBox(height: 400)`，测试与内嵌场景会这么用），需由 [build] 里的
  /// `LayoutBuilder` 再夹一道，否则内容会溢出（实测 `overflowed by 200 pixels`）。
  static double resolveHeight(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return (height * 0.54).clamp(360.0, 500.0);
  }

  @override
  Widget build(BuildContext context) =>
      // 在**本 widget 自身**拿到父级约束（而不是在 Column 的子项里）。
      //
      // 为什么不能把 LayoutBuilder 放在 Column 里面：`Column` 的子项拿到的是
      // **无界高度**（实测 `maxHeight=Infinity`），夹不到任何东西；必须包在
      // Column 外层，才能拿到调用方真正给的约束（如 `SizedBox(height: 400)`）。
      // 实测：不夹的话在 400px 高的容器里会 `overflowed by 200 pixels`。
      LayoutBuilder(
        builder: (context, constraints) {
          // 图片框 = **整屏**（用户反馈 2026-10-13：「我要的是全屏」）。
          // 这同时是"原图能显示多大"的前提，见 [TmdbBackdropSlideshow.height]。
          final screen = MediaQuery.sizeOf(context).height;
          final available = constraints.maxHeight;
          final frame = available.isFinite && available < screen
              ? available
              : screen;
          // 内容带 = 既有结论（约 54% 视口），且不能超过图片框。
          final band = (height ?? resolveHeight(context)).clamp(0.0, frame);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?statusBar,
              TmdbBackdropSlideshow(
                urls: data.backdropUrls,
                fallbackUrl: data.posterUrl,
                height: frame,
                contentBand: band,
                paintImage: paintImage,
                child: _HeaderContent(
                  data: data,
                  metadataBadge: metadataBadge,
                  overview: heroOverview,
                  actions: heroActions,
                ),
              ),
            ],
          );
        },
      );
}

/// 详情页附加区块（剧照墙 / 演职人员 / 相关推荐 / 相关视频 / 制作团队）。
///
/// 每个区块在数据为空时**整块隐藏**（`04` §3.4），不留空态占位。
class TmdbDetailSections extends StatelessWidget {
  const TmdbDetailSections({
    super.key,
    required this.data,
    this.recommendations = const [],
    this.videos = const [],
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
  });

  final TmdbDetailData data;
  final List<TmdbItem> recommendations;
  final List<TmdbVideo> videos;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final ValueChanged<TmdbItem>? onRecommendationTap;
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.photoUrls.isNotEmpty) ...[
          SectionHeader(
            title: '剧照（${data.photoUrls.length}）',
            keyValue: 'tmdb-section-photos',
          ),
          _PhotoWall(urls: data.photoUrls, title: data.title),
          const SizedBox(height: 16),
        ],
        // 海报墙（对齐上游 `@id/tmdbPosters` 的 Posters 区块）。
        // 与剧照是**不同语义**的两组图：剧照是剧中画面，海报是宣发图。
        if (data.posterUrls.length > 1) ...[
          SectionHeader(
            title: '海报（${data.posterUrls.length}）',
            keyValue: 'tmdb-section-posters',
          ),
          _PhotoWall(
            urls: data.posterUrls,
            title: data.title,
            keyPrefix: 'tmdb-poster',
            // 海报是 2:3 竖图：用窄框装竖图，避免横框里两侧露灰底。
            itemWidth: 110,
            aspectRatio: 2 / 3,
          ),
          const SizedBox(height: 16),
        ],
        if (data.allPeople.isNotEmpty || data.directors.isNotEmpty) ...[
          SectionHeader(
            title: '演职人员（${data.allPeople.length}）',
            keyValue: 'tmdb-section-people',
          ),
          _PeopleWall(
            people: data.allPeople.take(20).toList(),
            onTap: onPersonTap,
          ),
          const SizedBox(height: 16),
        ],
        // 制作团队**紧跟演职人员**（用户反馈 2026-10-10：「制作团队应该放在演员
        // 下方」）。对齐默影视 `activity_tmdb_detail.xml` 的区块顺序：
        // `castTitle`（演员）→ `creatorTitle`（制作团队）→ `relatedTitle`（相关推荐）。
        // 原先它排在相关视频之后，被两个大区块隔开，用户要滚很久才看得到。
        if (data.creatorTeam.isNotEmpty) ...[
          SectionHeader(
            title: '制作团队（${data.creatorTeam.length}）',
            keyValue: 'tmdb-section-crew',
          ),
          _PeopleWall(
            people: data.creatorTeam,
            onTap: onPersonTap,
            keyPrefix: 'tmdb-crew',
            keyValue: 'tmdb-crew-wall',
          ),
          const SizedBox(height: 16),
        ],
        if (recommendations.isNotEmpty) ...[
          SectionHeader(
            title: '相关推荐（${recommendations.length}）',
            keyValue: 'tmdb-section-recommendations',
          ),
          _RecommendationWall(
            items: recommendations,
            onTap: onRecommendationTap,
          ),
          const SizedBox(height: 16),
        ],
        if (videos.isNotEmpty) ...[
          SectionHeader(
            title: '相关视频（${videos.length}）',
            keyValue: 'tmdb-section-videos',
          ),
          for (final video in videos.take(8))
            TmdbVideoTile(
              video: video,
              onOpen: onOpenVideo,
              onCopy: onCopyVideo,
            ),
        ],
      ],
    );
  }
}

/// 线路选择器（`04` §3.1 ④）。
///
/// 对齐上游 `activity_video.xml` 的 `@id/flag`（`HorizontalGridView` 线路条）：
/// 点击一条线路就把该线路设为当前线路，下方剧集卡片随之切换成**该线路的集**。
///
/// 为什么必须是「点击切换」而不是「每条线路各渲染一屏卡片」：多线路站点动辄
/// 3–5 条线路，各渲染一屏卡片会把详情页拉成几屏长，用户还要自己找哪一屏是
/// 当前线路。上游同样只渲染当前线路的选集区。
class TmdbLineSelector extends StatelessWidget {
  const TmdbLineSelector({
    super.key,
    required this.lines,
    required this.selectedFlag,
    this.episodeCounts = const {},
    this.onChanged,
  });

  /// 全部线路（按详情页顺序）。
  final List<VodPlayLine> lines;

  /// 当前线路的 `flag`（空串表示未选中）。
  final String selectedFlag;

  /// 每条线路的**渲染集数**（已按当前季度过滤）。
  final Map<String, int> episodeCounts;

  final ValueChanged<VodPlayLine>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('tmdb-line-selector'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            '线路',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final line in lines) ...[
                    ChoiceChip(
                      key: ValueKey('tmdb-line-${line.flag}'),
                      label: Text(
                        episodeCounts.containsKey(line.flag)
                            ? '${line.displayName}（${episodeCounts[line.flag]} 集）'
                            : line.displayName,
                      ),
                      selected: line.flag == selectedFlag,
                      onSelected: onChanged == null
                          ? null
                          : (_) => onChanged!.call(line),
                    ),
                    const SizedBox(width: 8),
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

/// 剧集区块头：标题 + 集数 + 视图模式/正序倒序切换（`04` §3.1 ⑤）。
///
/// 对齐上游 `episodeHeader`（`episodeTitle` / `episodeReverse` /
/// `episodeViewMode`）与 `TmdbEpisodeGridPolicy`（列数策略）。
class TmdbEpisodeHeader extends StatelessWidget {
  const TmdbEpisodeHeader({
    super.key,
    required this.episodeCount,
    required this.reversed,
    required this.gridMode,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.lineName,
    this.title = '选集',
  });

  final int episodeCount;

  /// 区块标题（站点页用「选集」，纯 TMDB 页用「剧集」）。
  final String title;
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;

  /// 当前线路名（非空时拼进标题，使用户确认在看哪条线路）。
  final String? lineName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('tmdb-episode-header'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            [
              title,
              if (lineName != null && lineName!.isNotEmpty) lineName!,
              '$episodeCount 集',
            ].join(' · '),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('tmdb-episode-reverse'),
            onPressed: onToggleReversed,
            icon: Icon(
              reversed ? Icons.swap_vert : Icons.swap_vert,
              size: 16,
            ),
            label: Text(reversed ? '倒序' : '正序'),
          ),
          TextButton.icon(
            key: const ValueKey('tmdb-episode-view-mode'),
            onPressed: onToggleGridMode,
            icon: Icon(
              gridMode ? Icons.view_list : Icons.grid_view,
              size: 16,
            ),
            label: Text(gridMode ? '网格' : '列表'),
          ),
        ],
      ),
    );
  }
}

/// 剧集区块：区块头（选集/正序倒序/列表网格）+ 剧集海报卡片。
///
/// 站点详情页与纯 TMDB 详情页共用，避免两处各写一套导致行为漂移。
class TmdbEpisodeSection extends StatelessWidget {
  const TmdbEpisodeSection({
    super.key,
    required this.cards,
    required this.keyPrefix,
    this.actionLabel = '播放',
    this.onTap,
    this.lineName,
    this.cardWidth = 260,
    this.reversed = false,
    this.gridMode = false,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.title = '选集',
  });

  final List<TmdbEpisodeCard> cards;
  final String keyPrefix;
  final String actionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onTap;
  final String? lineName;
  final double cardWidth;
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TmdbEpisodeHeader(
        title: title,
        episodeCount: cards.length,
        reversed: reversed,
        gridMode: gridMode,
        lineName: lineName,
        onToggleReversed: onToggleReversed,
        onToggleGridMode: onToggleGridMode,
      ),
      TmdbEpisodeStrip(
        key: ValueKey('$keyPrefix-section'),
        cards: cards,
        keyPrefix: keyPrefix,
        actionLabel: actionLabel,
        cardWidth: cardWidth,
        gridMode: gridMode,
        onTap: onTap,
      ),
    ],
  );
}

/// 剧集海报卡片条（横向滚动）。
///
/// 这是详情页**唯一**的选集入口（用户反馈 2026-10-08）：有卡片时不再渲染
/// 下方的文字版集按钮，二者取其一。理由：同一集出现两种控件既是重复信息，
/// 也让用户在「点哪个」上犹豫；卡片信息量更大（剧照/集号/标题/日期/时长）。
///
/// 卡片数量恒等于线路剧集数（不补集、不丢集）。
class TmdbEpisodeStrip extends StatelessWidget {
  const TmdbEpisodeStrip({
    super.key,
    required this.cards,
    this.keyPrefix = 'tmdb-episode-card',
    this.actionLabel = '播放',
    this.onTap,
    this.cardWidth = 260,
    this.height = 196,
    this.gridMode = false,
  });

  final List<TmdbEpisodeCard> cards;
  final String keyPrefix;
  final String actionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onTap;

  /// 单卡宽度。
  ///
  /// 站点详情页会按「一屏能放下几列」动态计算（`04` §4.4 的列数策略）：
  /// 集数多的线路把卡做窄一些，使一行能看到更多集，减少横向滚动。
  final double cardWidth;
  final double height;

  /// 网格模式（对齐上游 `episodeGrid`）：换行铺满而不是横向滚动。
  ///
  /// 为什么需要：长剧集（几十集）在横向条里要滚很久，网格模式一屏能看到
  /// 更多集；上游同样提供「列表/网格」两种模式切换。
  final bool gridMode;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    if (gridMode) {
      return GridView.builder(
        key: ValueKey('$keyPrefix-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: cardWidth + 12,
          mainAxisExtent: height,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: cards.length,
        itemBuilder: (context, index) => TmdbEpisodeCardTile(
          buttonKey: ValueKey('$keyPrefix-$index'),
          stillKey: ValueKey('$keyPrefix-still-${cards[index].number}'),
          card: cards[index],
          actionLabel: actionLabel,
          onTap: onTap == null ? null : () => onTap!.call(index, cards[index]),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: ListView.separated(
        key: ValueKey('$keyPrefix-strip'),
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: cardWidth,
          child: TmdbEpisodeCardTile(
            buttonKey: ValueKey('$keyPrefix-$index'),
            stillKey: ValueKey('$keyPrefix-still-${cards[index].number}'),
            card: cards[index],
            actionLabel: actionLabel,
            onTap: onTap == null
                ? null
                : () => onTap!.call(index, cards[index]),
          ),
        ),
      ),
    );
  }
}

/// 详情页主体（站点页与纯 TMDB 页共用）。
class TmdbDetailView extends StatelessWidget {
  const TmdbDetailView({
    super.key,
    required this.data,
    this.episodeCards = const [],
    this.recommendations = const [],
    this.videos = const [],
    this.seasons = const [],
    this.selectedSeason = -1,
    this.selectableSeasons = const [],
    this.onSeasonChanged,
    this.onSelectSeason,
    this.seasonKeyPrefix = 'tmdb-season-card',
    this.episodeKeyPrefix = 'tmdb-episode-card',
    this.episodeActionLabel = '播放',
    this.onEpisodeTap,
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
    this.statusBar,
    this.metadataBadge,
    this.paintBackdrop = true,
    this.padding = const EdgeInsets.all(16),
    this.infoRows = const [],
    this.reversed = false,
    this.gridMode = false,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.episodeTitle = '剧集',
  });

  final TmdbDetailData data;

  /// 是否由本视图绘制背景图，默认 `true`。
  ///
  /// 传 `false` 用于**页面级固定背景**：调用方把本视图放进
  /// `Stack([Positioned.fill(背景), SingleChildScrollView(本视图)])`，
  /// 背景因此是视口大小且不随内容滚动（见 `tmdb_detail_page.dart` 的 `_buildContent`）。
  final bool paintBackdrop;

  final List<TmdbEpisodeCard> episodeCards;
  final List<TmdbItem> recommendations;
  final List<TmdbVideo> videos;

  /// 展示用季度（含海报）；为空时不渲染季度区块。
  final List<TmdbSeasonInfo> seasons;

  /// 当前选中的季度（`-1` 表示未确定）。
  final int selectedSeason;

  /// 可切换的季度号；为空但 [seasons] 非空时只展示不可切换。
  final List<int> selectableSeasons;
  final ValueChanged<int>? onSeasonChanged;

  /// 「选择季度」入口（未确定季度时，`04` §4.1）。
  final VoidCallback? onSelectSeason;

  /// 季度卡片的 key 前缀（纯 TMDB 页用 `tmdb-only-season`）。
  final String seasonKeyPrefix;
  final String episodeKeyPrefix;

  /// 剧集卡片的动作文案（`播放` / `搜索站源`）；空串表示无动作。
  final String episodeActionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onEpisodeTap;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final ValueChanged<TmdbItem>? onRecommendationTap;
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  /// 状态条（站点页的 TMDB 6 态状态条）插入在头部之上。
  final Widget? statusBar;

  /// 元数据徽标（纯 TMDB 页的「元数据季度 · 不可直接播放」）。
  final String? metadataBadge;

  final EdgeInsets padding;

  /// 信息表行（标签 → 值）；为空时不渲染信息表。
  final List<(String, String?)> infoRows;

  /// 剧集是否倒序 / 网格模式（对齐上游 `episodeReverse` / `episodeViewMode`）。
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;

  /// 剧集区块标题。
  final String episodeTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TmdbDetailHeader(
          // 页面级固定背景接管时传 `false`（见 `paintBackdrop` 的说明）。
          paintImage: paintBackdrop,
          data: data,
          statusBar: statusBar,
          metadataBadge: metadataBadge,
          heroOverview: data.overview,
        ),
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_seasonSectionVisible) ...[
                const SizedBox(height: 16),
                SectionHeader(
                  title: '季度',
                  keyValue: 'tmdb-section-seasons',
                  trailing: selectedSeason < 0 && onSelectSeason != null
                      ? TextButton(
                          key: const ValueKey('tmdb-choose-season'),
                          onPressed: onSelectSeason,
                          child: const Text('选择季度'),
                        )
                      : null,
                ),
                SizedBox(
                  height: 214,
                  child: ListView.separated(
                    key: const ValueKey('tmdb-season-strip'),
                    scrollDirection: Axis.horizontal,
                    itemCount: seasons.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final season = seasons[index];
                      final selectable = selectableSeasons.contains(
                        season.number,
                      );
                      return _SeasonCard(
                        key: ValueKey('$seasonKeyPrefix-${season.number}'),
                        season: season,
                        selected: season.number == selectedSeason,
                        selectable: selectable && onSeasonChanged != null,
                        onTap: selectable && onSeasonChanged != null
                            ? () => onSeasonChanged!.call(season.number)
                            : null,
                      );
                    },
                  ),
                ),
              ],
              if (infoRows.isNotEmpty) ...[
                const SizedBox(height: 16),
                TmdbInfoTable(rows: infoRows),
              ],
              const SizedBox(height: 16),
              if (episodeCards.isNotEmpty)
                EpisodeDurationStrip(cards: episodeCards),
              if (episodeCards.isEmpty)
                // 与其他页面的空态同一套结构（图标 + 标题），而不是一行裸文本。
                // 这是详情页截图里唯一看出来的不一致。
                const SizedBox(
                  width: double.infinity,
                  child: EmptyState(
                    key: ValueKey('tmdb-episodes-empty'),
                    icon: Icons.playlist_remove_outlined,
                    title: '没有可展示的剧集',
                  ),
                )
              else
                TmdbEpisodeSection(
                  key: const ValueKey('tmdb-section-episodes'),
                  title: episodeTitle,
                  cards: episodeCards,
                  keyPrefix: episodeKeyPrefix,
                  actionLabel: episodeActionLabel,
                  reversed: reversed,
                  gridMode: gridMode,
                  onToggleReversed: onToggleReversed,
                  onToggleGridMode: onToggleGridMode,
                  onTap: onEpisodeTap,
                ),
              if (data.photoUrls.isNotEmpty ||
                  data.allPeople.isNotEmpty ||
                  recommendations.isNotEmpty ||
                  videos.isNotEmpty ||
                  data.crew.isNotEmpty)
                TmdbDetailSections(
                  data: data,
                  recommendations: recommendations,
                  videos: videos,
                  onPersonTap: onPersonTap,
                  onRecommendationTap: onRecommendationTap,
                  onOpenVideo: onOpenVideo,
                  onCopyVideo: onCopyVideo,
                ),
            ],
          ),
        ),
      ],
    );
  }

  bool get _seasonSectionVisible =>
      seasons.isNotEmpty && (data.isTv || selectedSeason >= 0);
}

// ---------------------------------------------------------------------------
// 头部
// ---------------------------------------------------------------------------

class _HeaderContent extends StatelessWidget {
  const _HeaderContent({
    required this.data,
    this.metadataBadge,
    this.overview,
    this.actions,
  });

  final TmdbDetailData data;
  final String? metadataBadge;
  final String? overview;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final poster = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            key: const ValueKey('tmdb-detail-poster'),
            width: 150,
            height: 225,
            child: PosterImage(url: data.posterUrl),
          ),
        );
        final info = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.title,
                key: const ValueKey('tmdb-detail-title'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (data.originalTitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  data.originalTitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (data.tagline.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  data.tagline,
                  key: const ValueKey('tmdb-detail-tagline'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              _MetaChips(
                data: data,
                metadataBadge: metadataBadge,
                // 固定高度区域（动态背景 340px）内必须限制行数，否则窄窗口
                // 下 chips 换行会把标题挤出可视区并触发 overflow。
                maxChips: compact ? 4 : 7,
              ),
              if (data.directorLabel.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '导演：${data.directorLabel}',
                  key: const ValueKey('tmdb-detail-director'),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if ((overview ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Text(
                    overview!.trim(),
                    key: const ValueKey('tmdb-detail-hero-overview'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                      height: 1.35,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (actions != null) ...[
                const SizedBox(height: 12),
                actions!,
              ],
            ],
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [poster, const SizedBox(width: 16), info],
        );
      },
    );
  }
}

class _MetaChips extends StatelessWidget {
  const _MetaChips({required this.data, this.metadataBadge, this.maxChips = 7});

  final TmdbDetailData data;
  final String? metadataBadge;

  /// 最多展示几个 chip（窄窗口下少展示，避免把标题挤出动态背景区）。
  final int maxChips;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (data.ratingLabel.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-rating',
          icon: Icons.star,
          label: data.ratingLabel,
          emphasized: true,
        ),
      );
    }
    if (data.yearLabel.isNotEmpty) {
      chips.add(_Chip(keyValue: 'tmdb-detail-year', label: data.yearLabel));
    }
    if (data.runtimeLabel.isNotEmpty) {
      chips.add(
        _Chip(keyValue: 'tmdb-detail-runtime', label: data.runtimeLabel),
      );
    }
    if (data.seasonEpisodeLabel.isNotEmpty) {
      chips.add(
        _Chip(keyValue: 'tmdb-detail-seasons', label: data.seasonEpisodeLabel),
      );
    }
    if (data.genres.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-genres',
          label: data.genres.take(3).join(' / '),
        ),
      );
    }
    if (data.countries.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-countries',
          label: data.countries.take(2).join(' / '),
        ),
      );
    }
    if (data.status.isNotEmpty) {
      chips.add(_Chip(keyValue: 'tmdb-detail-status', label: data.status));
    }
    if (metadataBadge != null && metadataBadge!.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-only-metadata-badge',
          icon: Icons.info_outline,
          label: metadataBadge!,
        ),
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    final limited = chips.length <= maxChips
        ? chips
        : chips.sublist(0, maxChips);
    return Wrap(spacing: 8, runSpacing: 6, children: limited);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.keyValue,
    required this.label,
    this.icon,
    this.emphasized = false,
  });

  final String keyValue;
  final String label;
  final IconData? icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return TagChip(
      keyValue: keyValue,
      label: label,
      icon: icon,
      emphasized: emphasized,
    );
  }
}

// ---------------------------------------------------------------------------
// 区块通用
// ---------------------------------------------------------------------------

/// 详情信息表（`04` §3.1 ①）。
///
/// 为什么需要：上游 `activity_video.xml` 把 `site/year/area/type/director/actor`
/// 排成独立的元信息行，信息密度高且一眼可扫。早期 PC 端只用单列文字行，
/// 字段一多就显得「简陋」且占满纵向空间。这里改为两列对齐的表格：
/// 标签定宽、值自动换行，同一行放两组，字段多也不散。
class TmdbInfoTable extends StatelessWidget {
  const TmdbInfoTable({super.key, required this.rows});

  /// 标签 → 值；值为空或空串的行**自动跳过**（不留空行）。
  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = [
      for (final (label, value) in rows)
        if ((value ?? '').trim().isNotEmpty) (label, value!.trim()),
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    // 两列排布：奇数项时最后一行只有一个格子，右侧留白。
    final pairs = <List<(String, String?)>>[];
    for (var i = 0; i < visible.length; i += 2) {
      pairs.add([
        visible[i],
        if (i + 1 < visible.length) visible[i + 1],
      ]);
    }
    return Container(
      key: const ValueKey('tmdb-info-table'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < pairs.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var slot = 0; slot < 2; slot++) ...[
                  if (slot > 0) const SizedBox(width: 16),
                  Expanded(
                    child: pairs[i].length > slot
                        ? _InfoCell(
                            label: pairs[i][slot].$1,
                            value: pairs[i][slot].$2 ?? '',
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 季度卡片
// ---------------------------------------------------------------------------

class _SeasonCard extends StatelessWidget {
  const _SeasonCard({
    super.key,
    required this.season,
    required this.selected,
    required this.selectable,
    this.onTap,
  });

  final TmdbSeasonInfo season;
  final bool selected;
  final bool selectable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 128,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 170,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: selected ? 2 : 1,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: PosterImage(url: season.posterUrl),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              season.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selectable ? null : theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              season.subtitle,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 剧集卡片
// ---------------------------------------------------------------------------

/// 单集卡片：**剧照 + 集号 + 标题 + 播出日期**（`04` §4.2）。
///
/// 使用 [OutlinedButton] 作为外壳：既有集成门禁按
/// `OutlinedButton` + `episode-<flag>-<index>` 计数（不得补集），
/// 换成裸 `InkWell` 会让那条门禁失效。
/// 线路时长预算 + **按真实时长成比例**的剧集条。
///
/// 这是方向契约里从 Labanotation 借来的那条纪律「长度编码时长」——
/// 剧集不是等宽胶囊，条宽按真实时长成比例，"哪几集更长"一眼看得出来。
///
/// **位置是翻译过的**：契约原文写「右侧 348px」栏，但详情页 hero 的几何被测试
/// 锁死（背景必须铺满整窗宽，1200 视口下 `rect.width == 1200`），整页加右栏会
/// 直接打破它。所以这条纪律落在内容区、紧贴剧集区上方，而不是右栏。
///
/// 数据来自 [TmdbEpisodeCard.runtime]（分钟）。**`runtime == 0` 时如实显示
/// 「时长未知」**，不按平均值假装——编造比例就是编造数据。
class EpisodeDurationStrip extends StatelessWidget {
  const EpisodeDurationStrip({super.key, required this.cards});

  final List<TmdbEpisodeCard> cards;

  static String _formatTotal(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return hours > 0 ? '${hours}h ${rest}m' : '${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final known = cards.where((card) => card.runtime > 0).toList();
    if (known.isEmpty) {
      return Row(
        children: [
          Icon(
            Icons.timelapse_outlined,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            '各集时长未知',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    var maxRuntime = 0;
    var totalMinutes = 0;
    for (final card in known) {
      if (card.runtime > maxRuntime) maxRuntime = card.runtime;
      totalMinutes += card.runtime;
    }
    final unknownCount = cards.length - known.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '时长分布',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              '本线路共 ${_formatTotal(totalMinutes)}',
              style: tabular(
                theme.textTheme.bodySmall!.copyWith(color: scheme.onSurface),
              ),
            ),
            if (unknownCount > 0) ...[
              const SizedBox(width: AppSpace.sm),
              Text(
                '（$unknownCount 集时长未知）',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        // 条宽 = 该集时长 / 最长集：比例是真实的，不是均分。
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final card in cards)
              Tooltip(
                message: card.runtime > 0
                    ? 'E${card.number} · ${card.runtime} 分钟'
                    : 'E${card.number} · 时长未知',
                waitDuration: const Duration(milliseconds: 300),
                child: Container(
                  width: card.runtime > 0
                      ? 18 + (card.runtime / maxRuntime) * 62
                      : 8,
                  height: 18,
                  decoration: BoxDecoration(
                    // 中性数据墨色，**不用星等琥珀**：琥珀在本系统里只表示
                    // "星等/选中"（唯一强调色规则）。时长是数据，不是选中态——
                    // 给数据也上强调色会稀释强调色本身的含义。
                    // 未知集靠"更窄 + 更暗"区分，不靠颜色。
                    color: card.runtime > 0
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                        : scheme.surfaceContainerHighest,
                    borderRadius: AppRadius.smAll,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class TmdbEpisodeCardTile extends StatelessWidget {
  const TmdbEpisodeCardTile({
    super.key,
    this.buttonKey,
    this.stillKey,
    required this.card,
    this.actionLabel = '播放',
    this.onTap,
  });

  /// 剧照图片的 key。
  ///
  /// 必须由调用方带上**线路标识**：多条线路的同一集号是合法重复
  /// （`第 2 季第 1 集` 与 `第 1 季第 1 集` 都是 `E1`），共用同一个 key
  /// 会在同一棵树里产生重复 key，既影响查找也影响框架的 key 复用。
  final Key? stillKey;

  /// 外壳按钮的 key。
  ///
  /// 必须落在 [OutlinedButton] 上：既有集成门禁按
  /// `widget is OutlinedButton && widget.key is ValueKey<String> && key.startsWith('episode-<flag>-')`
  /// 计数（断言「不补集」），把 key 放在包装 widget 上会让那条门禁失效。
  final Key? buttonKey;

  final TmdbEpisodeCard card;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tooltip = actionLabel.isEmpty
        ? card.title
        : '$actionLabel · ${card.title}';
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        key: buttonKey,
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 剧照（16:9）；无剧照时显示占位（不隐藏卡片，否则会丢集）。
            SizedBox(
              height: 110,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      key:
                          stillKey ??
                          ValueKey('tmdb-episode-still-${card.number}'),
                      url: card.stillUrl,
                    ),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.78,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          card.seasonNumber > 0
                              ? 'S${card.seasonNumber}E${card.number}'
                              : 'E${card.number}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                    if (card.rating > 0)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.78,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            card.rating.toStringAsFixed(1),
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      if (card.date.isNotEmpty) card.date,
                      if (card.runtime > 0) '${card.runtime} 分钟',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 剧照墙（点击 → 大图查看器）
// ---------------------------------------------------------------------------

class _PhotoWall extends StatelessWidget {
  const _PhotoWall({
    required this.urls,
    required this.title,
    this.keyPrefix = 'tmdb-photo',
    this.itemWidth = 220,
    this.aspectRatio = 16 / 9,
  });

  final List<String> urls;
  final String title;

  /// 缩略图 key 前缀。
  ///
  /// 剧照墙与海报墙是两组不同的图，若共用 `tmdb-photo-N` 会出现重复 key，
  /// 点击定位也会歧义。因此由调用方给出各自前缀。
  final String keyPrefix;

  /// 单项宽度（高度由 [aspectRatio] 推出）。
  final double itemWidth;

  /// 单项宽高比。
  ///
  /// **必须按素材类型给**：剧照是 16:9 横图，海报是 2:3 竖图。早期实现对两者
  /// 都用同一个 220×140 的横框，竖版海报在横框里被缩成一条窄图居中，两侧露出
  /// 大片灰底——正是用户反馈「无效的背景色区域太丑」的来源之一
  /// （2026-10-09）。现在框比与素材一致，`BoxFit.cover` 就能恰好铺满。
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: itemWidth / aspectRatio,
      child: ListView.separated(
        key: const ValueKey('tmdb-photo-wall'),
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => InkWell(
          key: ValueKey('$keyPrefix-$index'),
          onTap: () => showTmdbPhotoViewer(
            context,
            urls: urls,
            url: urls[index],
            title: title,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: itemWidth,
              child: PosterImage(url: urls[index], fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开图片查看器（`04` §3.1 ⑥）。返回后无需刷新任何状态。
Future<void> showTmdbPhotoViewer(
  BuildContext context, {
  required List<String> urls,
  required String url,
  String title = '',
}) {
  final viewer = TmdbPhotoViewer.open(urls: urls, url: url, title: title);
  if (viewer.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => TmdbPhotoViewerDialog(viewer: viewer),
  );
}

/// 图片查看器：大图 + 左右翻页 + 键盘（`←/→` 翻页、`Esc` 关闭）。
class TmdbPhotoViewerDialog extends StatefulWidget {
  const TmdbPhotoViewerDialog({super.key, required this.viewer});

  final TmdbPhotoViewer viewer;

  @override
  State<TmdbPhotoViewerDialog> createState() => _TmdbPhotoViewerDialogState();
}

class _TmdbPhotoViewerDialogState extends State<TmdbPhotoViewerDialog> {
  late TmdbPhotoViewer _viewer = widget.viewer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('tmdb-photo-viewer'),
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      // 独立 `RepaintBoundary`：使查看器可以被单独光栅化（截图证据需要
      // 「只拍对话框」；对话框在 overlay 里，取整窗会拍到被压在下面的页面）。
      child: RepaintBoundary(
        key: const ValueKey('tmdb-photo-viewer-boundary'),
        // 显式限定尺寸：`Dialog` 只给宽松约束，不限高会让查看器铺满整屏高度
        // （截图证据里就是一张 1552x5952 的怪图）。这里给一个「大图窗口」的
        // 合理上限，既符合桌面观感，也让证据可读。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 820),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
              SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousIntent(),
              SingleActivator(LogicalKeyboardKey.escape): _CloseIntent(),
            },
            child: Actions(
              actions: {
                _NextIntent: CallbackAction<_NextIntent>(
                  onInvoke: (_) {
                    setState(() => _viewer = _viewer.next());
                    return null;
                  },
                ),
                _PreviousIntent: CallbackAction<_PreviousIntent>(
                  onInvoke: (_) {
                    setState(() => _viewer = _viewer.previous());
                    return null;
                  },
                ),
                _CloseIntent: CallbackAction<_CloseIntent>(
                  onInvoke: (_) {
                    Navigator.of(context).pop();
                    return null;
                  },
                ),
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_viewer.title.isEmpty ? '图片' : _viewer.title}'
                              ' · ${_viewer.index + 1}/${_viewer.count}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('tmdb-photo-viewer-close'),
                            tooltip: '关闭',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          InteractiveViewer(
                            child: PosterImage(
                              key: const ValueKey('tmdb-photo-viewer-image'),
                              url: _viewer.currentUrl,
                              fit: BoxFit.contain,
                            ),
                          ),
                          if (_viewer.hasPrevious)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton.filledTonal(
                                key: const ValueKey('tmdb-photo-viewer-prev'),
                                tooltip: '上一张',
                                onPressed: () => setState(
                                  () => _viewer = _viewer.previous(),
                                ),
                                icon: const Icon(Icons.chevron_left),
                              ),
                            ),
                          if (_viewer.hasNext)
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton.filledTonal(
                                key: const ValueKey('tmdb-photo-viewer-next'),
                                tooltip: '下一张',
                                onPressed: () =>
                                    setState(() => _viewer = _viewer.next()),
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

// ---------------------------------------------------------------------------
// 演职人员墙（点击 → 人物页）
// ---------------------------------------------------------------------------

class _PeopleWall extends StatelessWidget {
  const _PeopleWall({
    required this.people,
    this.onTap,
    this.keyPrefix = 'tmdb-person',
    this.keyValue = 'tmdb-people-wall',
  });

  final List<TmdbPerson> people;
  final ValueChanged<TmdbPerson>? onTap;

  /// 卡片 key 前缀。
  ///
  /// 演员墙与制作团队墙是两组不同的人，若共用 `tmdb-person-<id>` 会出现重复
  /// key（同一个人可能既在 cast 又在 crew），点击回调也会歧义。
  final String keyPrefix;
  final String keyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 178,
      child: ListView.separated(
        key: ValueKey(keyValue),
        scrollDirection: Axis.horizontal,
        itemCount: people.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final person = people[index];
          return SizedBox(
            width: 104,
            child: InkWell(
              key: ValueKey('$keyPrefix-${person.personId}'),
              onTap: onTap == null ? null : () => onTap!.call(person),
              borderRadius: BorderRadius.circular(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 116,
                      child: PosterImage(url: person.profileUrl),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    person.name,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    person.subtitle,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 相关推荐墙（点击 → 进入该作品详情）
// ---------------------------------------------------------------------------

class _RecommendationWall extends StatelessWidget {
  const _RecommendationWall({required this.items, this.onTap});

  final List<TmdbItem> items;
  final ValueChanged<TmdbItem>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 218,
      child: ListView.separated(
        key: const ValueKey('tmdb-recommendation-wall'),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final key = item.identity?.key ?? 'item-$index';
          return SizedBox(
            width: 130,
            child: InkWell(
              key: ValueKey('tmdb-recommendation-$key'),
              onTap: onTap == null ? null : () => onTap!.call(item),
              borderRadius: BorderRadius.circular(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 180,
                      child: PosterImage(url: item.posterUrl),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.subtitle,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 单集详情弹窗
// ---------------------------------------------------------------------------

/// 打开单集详情弹窗（剧照 + 简介 + 动作）。
Future<void> showTmdbEpisodeSheet(
  BuildContext context, {
  required TmdbEpisodeCard card,
  String actionLabel = '播放',
  VoidCallback? onAction,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TmdbEpisodeSheet(
      card: card,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

/// 单集详情弹窗（`04` §4.2：剧照 + 标题 + 播出日期 + 简介）。
class TmdbEpisodeSheet extends StatelessWidget {
  const TmdbEpisodeSheet({
    super.key,
    required this.card,
    this.actionLabel = '播放',
    this.onAction,
  });

  final TmdbEpisodeCard card;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      key: const ValueKey('tmdb-episode-sheet'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 260,
                  width: double.infinity,
                  child: PosterImage(
                    key: const ValueKey('tmdb-episode-sheet-still'),
                    url: card.stillUrl,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                card.title,
                key: const ValueKey('tmdb-episode-sheet-title'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                [
                  card.subtitle,
                  if (card.runtime > 0) '${card.runtime} 分钟',
                  if (card.rating > 0) '★ ${card.rating.toStringAsFixed(1)}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              if (card.overview != null &&
                  card.overview!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  card.overview!.trim(),
                  key: const ValueKey('tmdb-episode-sheet-overview'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  if (actionLabel.isNotEmpty)
                    FilledButton.icon(
                      key: const ValueKey('tmdb-episode-sheet-action'),
                      onPressed: onAction == null
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              onAction!.call();
                            },
                      icon: const Icon(Icons.play_arrow),
                      label: Text(actionLabel),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 人物页（演职人员点击）
// ---------------------------------------------------------------------------

/// 人物页的一行筛选 chip（部门 / 类型）。
///
/// 横向可滚动：部门可能多达十几个（导演/编剧/制片/摄影/剪辑…），窄窗口下必须能滚。
/// 选项带计数，选中态用主色淡底 + 主色文字（与浏览页筛选条同一视觉语言）。
class PersonWorkFilterRow extends StatelessWidget {
  const PersonWorkFilterRow({
    super.key,
    required this.keyValue,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final String keyValue;
  final List<PersonWorkFilterOption> options;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 34,
      child: ListView.separated(
        key: ValueKey(keyValue),
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final option = options[index];
          final isSelected = option.key == selected;
          return InkWell(
            key: ValueKey('$keyValue-${option.key}'),
            onTap: () => onSelected(option.key),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected
                    ? scheme.primary.withValues(alpha: 0.18)
                    : scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                '${option.label} ${option.count}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 人物页：简介 + 照片 + 作品列表（`04` §6.1 的演职人员作品入口）。
class TmdbPersonPage extends StatefulWidget {
  const TmdbPersonPage({
    super.key,
    required this.service,
    required this.person,
    this.onOpenItem,
    this.onOpenPhoto,
  });

  final TmdbService service;
  final TmdbPerson person;

  /// 点击作品：进入该作品的 TMDB 详情。
  final ValueChanged<TmdbItem>? onOpenItem;

  /// 点击照片（默认打开内置查看器）。
  final void Function(List<String> urls, String url)? onOpenPhoto;

  @override
  State<TmdbPersonPage> createState() => _TmdbPersonPageState();
}

class _TmdbPersonPageState extends State<TmdbPersonPage> {
  TmdbLoadPhase _phase = TmdbLoadPhase.loading;
  AppError? _error;
  Map<String, Object?>? _detail;
  List<String> _photos = const [];
  List<TmdbPersonWork> _works = const [];

  /// 作品筛选器（两个维度：部门 / 类型），对齐默影视 `TmdbPersonWorkFilters`。
  ///
  /// 用户反馈 2026-10-10：「人员介绍页也不支持按分类筛选：电视，电影，参演，
  /// 导演等」。默认两个维度都是「全部」。
  PersonWorkFilters? _workFilters;
  String _departmentFilter = PersonWorkDepartment.all;
  String _mediaFilter = PersonWorkMedia.all;
  bool _biographyExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _phase = TmdbLoadPhase.loading;
      _error = null;
    });
    try {
      final detail = await widget.service.person(widget.person.personId);
      if (!mounted) return;
      final config = widget.service.config;
      final credits = detail['combined_credits'];
      final creditMap = credits is Map
          ? credits.cast<Object?, Object?>()
          : const <Object?, Object?>{};
      final castWorks = TmdbPersonWork.listFrom(
        creditMap['cast'],
        image: TmdbImageSelector.image,
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
        cast: true,
      );
      final crewWorks = TmdbPersonWork.listFrom(
        creditMap['crew'],
        image: TmdbImageSelector.image,
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
        cast: false,
      );
      final works = <TmdbPersonWork>[...castWorks, ...crewWorks];
      setState(() {
        _detail = detail;
        _photos = TmdbImageSelector.profiles(
          detail,
          config.imageBase,
          limit: 12,
        );
        _works = works;
        // 筛选器由 cast/crew **分开**构造：`cast` 一律算「出演」，`crew` 按
        // job/department 归一后的中文身份归类（对齐默影视）。
        _workFilters = PersonWorkFilters.from(castWorks, crewWorks);
        _departmentFilter = PersonWorkDepartment.all;
        _mediaFilter = PersonWorkMedia.all;
        _phase = TmdbLoadPhase.ready;
      });
    } on TmdbAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = AppError(
          AppErrorKind.tmdbAuth,
          'TMDB 鉴权失败',
          detail: error.message,
          statusCode: error.statusCode,
        );
        _phase = TmdbLoadPhase.failed;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AppError
            ? error
            : AppError(
                AppErrorKind.tmdbNetwork,
                'TMDB 请求失败',
                detail: '$error',
                retryable: true,
              );
        _phase = TmdbLoadPhase.failed;
      });
    }
  }

  /// 当前筛选下的作品（筛选器未就绪时退化为全部）。
  List<TmdbPersonWork> get _filteredWorks =>
      _workFilters?.filter(
        department: _departmentFilter,
        media: _mediaFilter,
      ) ??
      _works;

  /// 两行筛选 chip：部门 / 类型（对齐默影视 `filterGroup`）。
  List<Widget> _buildWorkFilters(BuildContext context) {
    final filters = _workFilters!;
    return [
      const SizedBox(height: 8),
      PersonWorkFilterRow(
        keyValue: 'tmdb-person-filter-department',
        options: filters.departmentOptions(),
        selected: _departmentFilter,
        onSelected: (key) => setState(() => _departmentFilter = key),
      ),
      const SizedBox(height: 6),
      PersonWorkFilterRow(
        keyValue: 'tmdb-person-filter-media',
        options: filters.mediaOptions(),
        selected: _mediaFilter,
        onSelected: (key) => setState(() => _mediaFilter = key),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final person = widget.person;
    return Scaffold(
      key: const ValueKey('tmdb-person-page'),
      appBar: AppBar(title: Text(person.name)),
      body: switch (_phase) {
        TmdbLoadPhase.idle || TmdbLoadPhase.loading => const LoadingBlock(),
        TmdbLoadPhase.disabled => Center(
          child: Text('未配置 TMDB（不影响站源浏览与播放）', style: theme.textTheme.bodyLarge),
        ),
        TmdbLoadPhase.failed => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                describeTmdbFailure(_error),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('tmdb-person-retry'),
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        TmdbLoadPhase.ready => _buildContent(context),
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail ?? const <String, Object?>{};
    final biography = tmdbFirstNonEmpty([
      detail['biography'],
      widget.person.biography,
    ]);
    final department = tmdbFirstNonEmpty([
      detail['known_for_department'],
      widget.person.knownForDepartment,
    ]);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 150,
                height: 225,
                child: PosterImage(url: widget.person.profileUrl),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tmdbFirstNonEmpty([detail['name'], widget.person.name]),
                    key: const ValueKey('tmdb-person-name'),
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (department.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(department, style: theme.textTheme.bodyMedium),
                  ],
                  if (widget.person.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.person.subtitle,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (biography.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '简介',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            biography,
            key: const ValueKey('tmdb-person-biography'),
            style: theme.textTheme.bodyMedium,
            maxLines: _biographyExpanded ? null : 6,
            overflow: _biographyExpanded ? null : TextOverflow.ellipsis,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('tmdb-person-biography-toggle'),
              onPressed: () =>
                  setState(() => _biographyExpanded = !_biographyExpanded),
              child: Text(_biographyExpanded ? '收起' : '展开'),
            ),
          ),
        ],
        if (_photos.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '照片（${_photos.length}）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: ListView.separated(
              key: const ValueKey('tmdb-person-photos'),
              scrollDirection: Axis.horizontal,
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => InkWell(
                key: ValueKey('tmdb-person-photo-$index'),
                onTap: () {
                  if (widget.onOpenPhoto != null) {
                    widget.onOpenPhoto!(_photos, _photos[index]);
                    return;
                  }
                  showTmdbPhotoViewer(
                    context,
                    urls: _photos,
                    url: _photos[index],
                    title: widget.person.name,
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    // 人物照片是 2:3 竖图：框比与素材一致，不让两侧露灰底。
                    width: 100,
                    height: 150,
                    child: PosterImage(url: _photos[index], fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_works.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '作品（${_filteredWorks.length}'
            '${_filteredWorks.length == _works.length ? '' : ' / ${_works.length}'}）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // 筛选条（对齐默影视 `activity_tmdb_person.xml` 的 `filterGroup`）：
          // 两行 chip——部门（全部部门/出演/导演/编剧/…）与类型（全部类型/电影/剧集）。
          // 每个选项带计数，无作品的选项不出现（避免选了没结果）。
          if (_workFilters != null) ..._buildWorkFilters(context),
          const SizedBox(height: 8),
          if (_filteredWorks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '该筛选下没有作品',
                  key: const ValueKey('tmdb-person-works-empty'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            )
          else
            GridView.builder(
              key: const ValueKey('tmdb-person-works'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: 280,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _filteredWorks.length,
              itemBuilder: (context, index) {
                final work = _filteredWorks[index];
                final key = work.item.identity?.key ?? 'work-$index';
                return InkWell(
                  key: ValueKey('tmdb-person-work-$key'),
                  onTap: widget.onOpenItem == null
                      ? null
                      : () => widget.onOpenItem!.call(work.item),
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: 220,
                          child: PosterImage(url: work.item.posterUrl),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        work.item.title,
                        style: theme.textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        work.subtitle,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ],
    );
  }
}
