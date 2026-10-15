/// 搜索页：联想、历史、热门推荐、范围限定、多站点并发搜索、结果筛选与分页
/// （§14.1、§14.3、§17.2）。
///
/// 对齐上游安卓「默影视」SearchFragment + CollectFragment 的功能集：
/// - **联想**：输入即取爱奇艺 + 腾讯双源联想，下拉选择即搜（上游 `getSuggest`）；
/// - **搜索历史**：去重、最新在前、上限 10 条，可单条删除 / 全清
///   （上游 `RecordAdapter`），持久化在 `settings.json`；
/// - **热门推荐**：360kan 电影 / 剧集 / 综艺榜单（上游 `getHot`），
///   断网时回退磁盘缓存；
/// - **搜索范围**：全部 / 当前站点 / 某分组（上游 `SearchFragment` 的 scope 菜单）；
/// - **结果筛选**：按分组（站点名方括号标记）与相似度阈值过滤
///   （上游 `CollectFragment` 的 `action_group` / `action_similarity`）；
/// - **结果分页**：滚动到底自动翻下一页 + 「加载更多」兜底，内容重复即判该站点
///   耗尽（上游 `CustomScroller` + `SearchPageState`）；
/// - **站点侧栏**：结果按站点聚合，「全部」合并视图 + 单站点视图点击切换，
///   不用再在混排列表里翻找自己喜欢的站点（上游 `CollectAdapter` 侧栏）。
///
/// 搜索批次本身的多站点并发 / 失败不阻塞 / 可取消语义见 `AppState.searchAll`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/hot_rank_layout.dart';
import '../core/protocol.dart';
import '../core/search_result_filter.dart';
import '../core/tmdb_identity.dart';
import '../services/search_suggest_service.dart';
import '../state/app_state.dart';
import '../state/search_state.dart';
import 'app.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'tokens.dart';

/// 相似度预设档位（与「自定义…」滑块互补）。
const List<int> _similarityPresets = [0, 30, 60, 100];

/// 热门推荐区的头部高度（标题行 24 + 间距 8 + 类目 tab 32）。
///
/// 必须是**与实际布局一致**的精确值：网格可用高度用
/// `maxHeight - _hotHeaderHeight` 算，而头部又被强制放在这个高度的盒子里，
/// 两边一致才能保证「列 × 行」恰好铺满而不是溢出或空一行。
const double _hotHeaderHeight = 64;

/// 相似度自动续翻的最大跳数。
///
/// 为什么需要上限：上游未声明总页数（`pageCount == 0`）时页码没有硬上限，
/// 若对端一直返回「新内容但都被过滤掉」的页，没有上限就会一直翻下去。
const int _maxAutoPagingHops = 8;

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    this.initialKeyword,
    this.identityHint,
  });

  final AppState state;

  /// 预填关键词（纯 TMDB 详情页「搜索站源」入口带入标题，`04` §6.2）。
  final String? initialKeyword;

  /// 身份提示（`tmdbId`），便于搜索结果自动匹配（`04` §6.2）。
  final TmdbIdentity? identityHint;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 联想层可见性：输入非空且获得焦点时展开。
  bool _suggestVisible = false;

  /// 联想词（保序去重后）。null = 尚未请求（不发联想请求时恢复热搜区）。
  List<SearchSuggestItem>? _suggestions;

  /// 上一次已响应的输入文本。
  ///
  /// 为什么需要它：`TextEditingController` 在**选区变化**时也会通知监听者，
  /// 而 `controller.text = x` 会把 selection 置为 -1（同样是「值变化」）——
  /// 于是提交搜索后重设文本又触发一次 `_onInputChanged`，把刚收起的联想面板
  /// 重新打开（实测：点「搜索」后结果区被联想下拉盖住）。只按文本内容变化
  /// 响应，选区抖动一律忽略。
  String _lastInput = '';

  /// 联想防抖计时器。
  Timer? _suggestDebounce;

  /// 联想请求序号：输入变化后旧响应作废（上游 `mSuggestSeq`）。
  int _suggestSeq = 0;

  /// 热门推荐：电影 / 剧集 / 综艺。
  Map<HotRankCategory, List<SearchSuggestItem>> _hotRanks = const {};

  /// 热门区当前展开的类目（默认电影）。
  HotRankCategory _hotTab = HotRankCategory.movie;

  /// 各个类目的「换一批」窗口起点（候选池下标；`hotRankWindow` 会回绕）。
  ///
  /// 按类目分开记：切回某个类目时应接着上次那一批，而不是跳回第一批。
  final Map<HotRankCategory, int> _hotOffsets = {};

  // ---- 搜索范围（对齐上游 SearchFragment 的 scope 菜单）----

  /// 范围：限定站点 key；空串 = 不限定。
  String _scopeSiteKey = '';

  /// 范围：限定分组；空串 = 不限定。与 [_scopeSiteKey] 互斥。
  String _scopeGroup = '';

  // ---- 结果筛选状态（对齐上游 CollectFragment）----

  /// 当前选中的站点 key；[_allSitesKey] = 全部聚合视图。
  static const String _allSitesKey = '__all__';
  String _activeSiteKey = _allSitesKey;

  /// 分组筛选；空串 = 全部分组。
  String _filterGroup = '';

  /// 相似度阈值（页面快照；保存走 `state.setSearchSimilarity`）。
  int _similarity = 30;

  /// 结果区滚动控制器：滚动到底触发自动翻页。
  final ScrollController _resultScroll = ScrollController();

  /// 是否有自动续翻正在跑（防止滚动回调重入）。
  bool _autoPaging = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    _similarity = widget.state.searchSimilarity;
    _controller.addListener(_onInputChanged);
    _resultScroll.addListener(_onResultScroll);
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      // 带入标题后**自动执行一次搜索**（对齐手动匹配弹窗「打开即搜索」）。
      _controller.text = keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit();
      });
    } else {
      // 不带关键词进来（切回搜索页/首次进入）→ 把上一轮残留的结果丢掉，
      // 否则再输入时会先闪出旧结果（`_activeSearch` 跨页面存活）。
      // 放 post-frame：`clearSearch` 会 notifyListeners，而此刻还在父级 build 中。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.state.clearSearch();
      });
      _loadHotRanks();
    }
  }

  @override
  void dispose() {
    // 离开页面必须取消在途搜索，避免结果投递到已销毁的页面（§14.1）。
    _suggestDebounce?.cancel();
    widget.state.removeListener(_onStateChanged);
    widget.state.cancelSearch();
    _controller.removeListener(_onInputChanged);
    _resultScroll.removeListener(_onResultScroll);
    _resultScroll.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  AppState get _state => widget.state;

  // ---------------------------------------------------------------------------
  // 输入、联想、提交
  // ---------------------------------------------------------------------------

  void _onInputChanged() {
    final text = _controller.text.trim();
    // 选区变化（含 `text = x` 把 selection 置 -1）不是输入变化，不得重开联想。
    if (text == _lastInput) return;
    _lastInput = text;
    _suggestDebounce?.cancel();
    if (text.isEmpty) {
      // 清空输入 → 收起联想、丢掉残留结果、回到历史 + 热门（上游 `getWord` 分支）。
      _suggestSeq++;
      _state.clearSearch();
      if (_suggestions != null || _suggestVisible) {
        setState(() {
          _suggestions = null;
          _suggestVisible = false;
        });
      }
      return;
    }
    // 防抖 250ms：联想接口按击键打太多没意义（上游也是文本变化即发，但桌面端
    // 键盘输入频率更高，防抖能砍掉绝大多数中间态请求）。
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _suggestVisible = true);
      _fetchSuggestions(text);
    });
  }

  Future<void> _fetchSuggestions(String text) async {
    final seq = ++_suggestSeq;
    final items = await _state.searchSuggest(text);
    if (!mounted || seq != _suggestSeq) return;
    if (_controller.text.trim() != text) return;
    setState(() => _suggestions = items);
  }

  Future<void> _loadHotRanks() async {
    final categories = HotRankCategory.values;
    final results = await Future.wait([
      for (final category in categories) _state.searchHotRank(category),
    ]);
    if (!mounted) return;
    setState(() {
      _hotRanks = {
        for (var i = 0; i < categories.length; i++)
          categories[i]: results[i],
      };
    });
  }

  Future<void> _submit([String? keyword]) async {
    final text = (keyword ?? _controller.text).trim();
    if (text.isEmpty) return;
    _suggestDebounce?.cancel();
    _suggestSeq++;
    // 先登记文本再赋值：赋值会因 selection 变化触发监听，登记后那次通知会被
    // `_lastInput` 相等判定忽略（否则结果区会被联想面板盖住）。
    _lastInput = text;
    _controller.text = text;
    _focusNode.requestFocus();
    _focusNode.unfocus();
    setState(() {
      _suggestVisible = false;
      _suggestions = null;
      _activeSiteKey = _allSitesKey;
      _filterGroup = '';
    });
    _scrollResultsToTop();
    await _state.searchAll(
      text,
      siteKey: _scopeSiteKey,
      group: _scopeGroup,
    );
  }

  /// 搜索页回到「未搜索」状态：清空输入 → 收起联想 → 丢掉结果。
  ///
  /// 清空输入会走 `_onInputChanged` 的空分支（收起联想 + `clearSearch`），
  /// 这里只需把结果区自己的筛选态一并复位。
  void _backToLanding() {
    _suggestDebounce?.cancel();
    _suggestSeq++;
    _controller.clear();
    setState(() {
      _suggestVisible = false;
      _suggestions = null;
      _activeSiteKey = _allSitesKey;
      _filterGroup = '';
    });
  }

  /// 联想 / 历史 / 热门点击 → 直接搜该词。
  void _searchFrom(String keyword) => _submit(keyword);

  // ---------------------------------------------------------------------------
  // 搜索范围（上游 SearchFragment 的 scope 菜单）
  // ---------------------------------------------------------------------------

  String? _siteNameOf(String key) {
    for (final item in _state.siteItems) {
      if (item.site.key == key) return item.site.name;
    }
    return null;
  }

  String get _scopeLabel {
    if (_scopeGroup.isNotEmpty) return '分组：$_scopeGroup';
    if (_scopeSiteKey.isNotEmpty) {
      final name = _siteNameOf(_scopeSiteKey);
      return name == null ? _scopeSiteKey : '当前站点：$name';
    }
    return '全部站点';
  }

  bool get _scopeScoped => _scopeSiteKey.isNotEmpty || _scopeGroup.isNotEmpty;

  /// 范围选择器（全部 / 当前站点 / 各分组）。
  Widget _buildScopeButton() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedSite = _state.selectedSite;
    final groups = _state.searchScopeGroups;
    final scoped = _scopeScoped;
    return PopupMenuButton<String>(
      key: const ValueKey('search-scope'),
      tooltip: '搜索范围',
      position: PopupMenuPosition.under,
      onSelected: _onScopeSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          key: ValueKey('search-scope-all'),
          value: 'all',
          child: Text('全部站点'),
        ),
        if (selectedSite != null && selectedSite.searchable)
          PopupMenuItem(
            key: const ValueKey('search-scope-site'),
            value: 'site',
            child: Text('当前站点：${selectedSite.name}'),
          ),
        for (final group in groups)
          PopupMenuItem(
            key: ValueKey('search-scope-group-$group'),
            value: 'group:$group',
            child: Text('分组：$group'),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.md,
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: scoped ? scheme.primary : scheme.outlineVariant,
          ),
          borderRadius: AppRadius.mdAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 18,
              color: scoped ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpace.sm),
            Text(_scopeLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }

  void _onScopeSelected(String value) {
    setState(() {
      if (value == 'all') {
        _scopeSiteKey = '';
        _scopeGroup = '';
      } else if (value == 'site') {
        _scopeSiteKey = _state.selectedSite?.key ?? '';
        _scopeGroup = '';
      } else if (value.startsWith('group:')) {
        _scopeSiteKey = '';
        _scopeGroup = value.substring('group:'.length);
      }
    });
    // 范围变了就必须重搜——否则用户看到的是旧范围的旧结果（上游是回上一页
    // 重新进搜索页，PC 端直接按新范围重搜更直接）。
    if (_outcome != null) unawaited(_submit());
  }

  Future<void> _openResult(SiteSearchEntry entry, Vod vod) async {
    final site = _state.siteItems
        .where((item) => item.site.key == entry.siteKey)
        .map((item) => item.site)
        .firstOrNull;
    if (site == null) return;
    // 先切站点：详情与播放解析都依赖「当前站点」，否则会串到别的站点去取详情。
    await _state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: _state, vod: vod),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 结果筛选（上游 CollectFragment 的 group / similarity / 站点侧栏）
  // ---------------------------------------------------------------------------

  MultiSiteSearchOutcome? get _outcome => _state.activeSearch;

  /// 分组筛选后的站点条目。
  List<SiteSearchEntry> get _groupFilteredEntries {
    final outcome = _outcome;
    if (outcome == null) return const [];
    if (_filterGroup.isEmpty) return outcome.results;
    return [
      for (final entry in outcome.results)
        if (entry.groups.contains(_filterGroup)) entry,
    ];
  }

  /// 按当前相似度阈值过滤某站点的条目。
  List<Vod> _visibleOf(SiteSearchEntry entry) => filterSearchResults(
    entry.result?.list ?? const [],
    _outcome?.keyword ?? '',
    _similarity,
    titleOf: (vod) => vod.vodName,
  );

  /// 侧栏/结果区用的「有原始条目的站点」（保留被相似度滤成空的站点，
  /// 否则用户无法选中它继续翻页去找命中项）。
  List<SiteSearchEntry> get _rawEntries => [
    for (final entry in _groupFilteredEntries)
      if (entry.succeeded && entry.itemCount > 0) entry,
  ];

  /// 结果里出现过的分组（按站点顺序去重；只统计**有结果**的站点，
  /// 空分组 chip 没有意义——上游 `Site.getGroups(mSites)` 同样只列真实分组）。
  List<String> get _resultGroups {
    final seen = <String>[];
    for (final entry in _groupFilteredEntries) {
      if (!entry.succeeded || entry.itemCount == 0) continue;
      for (final group in entry.groups) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  /// 当前选中的站点条目（未过滤相似度的原始条目）；「全部」视图时为 null。
  SiteSearchEntry? get _activeEntry {
    if (_activeSiteKey == _allSitesKey) return null;
    final outcome = _outcome;
    if (outcome == null) return null;
    for (final entry in _groupFilteredEntries) {
      if (entry.siteKey == _activeSiteKey) return entry;
    }
    return null;
  }

  /// 「全部」视图聚合的可见条目（按站点顺序拼接）。
  List<Vod> get _allViewVods => [
    for (final entry in _rawEntries) ..._visibleOf(entry),
  ];

  // ---------------------------------------------------------------------------
  // 结果分页（上游 CustomScroller + SearchPageState）
  // ---------------------------------------------------------------------------

  void _scrollResultsToTop() {
    if (!_resultScroll.hasClients) return;
    _resultScroll.jumpTo(0);
  }

  void _onResultScroll() {
    if (!_resultScroll.hasClients) return;
    final position = _resultScroll.position;
    // 距底部不足 240px 就预取下一页（提前量让滚动不至于停顿）。
    if (position.extentAfter > 240) return;
    unawaited(_loadMore());
  }

  /// 翻一页结果。
  ///
  /// 三处调用：滚动到底（不限条件）、用户点「加载更多」（不限条件）、
  /// 以及 [auto] 触发的「选中站点/改阈值」——后者必须等上游
  /// `shouldContinue` 的条件成立才值得翻（相似度 > 0 且当前页过滤后全不可见），
  /// 否则会在用户刚选中站点时就把在看的内容换掉、还白打网络请求。
  ///
  /// 翻完后若这一页「原始有条目但被相似度整页滤掉」，继续自动续翻
  /// （上游 `CollectFragment.maybeLoadNextPage`），带上限防止无限翻。
  Future<void> _loadMore({bool auto = false}) async {
    if (_autoPaging) return;
    _autoPaging = true;
    try {
      for (var hop = 0; hop < _maxAutoPagingHops; hop++) {
        if (!mounted) return;
        final entry = _activeEntry;
        if (entry == null || entry.loadingMore || !entry.hasMore) return;
        final rawBefore = entry.itemCount;
        final visibleBefore = _visibleOf(entry).length;
        if (auto && hop == 0 && !(_similarity > 0 && visibleBefore == 0)) {
          return;
        }
        final accepted = await _state.loadMoreSearch(entry.siteKey);
        if (!mounted || !accepted) return;
        final after = _state.activeSearch?.entryOf(entry.siteKey);
        if (after == null) return;
        final rawGrew = after.itemCount > rawBefore;
        final visibleGrew = _visibleOf(after).length > visibleBefore;
        // 这一页有原始条目、但过滤后仍然一条都看不见 → 继续翻（否则用户看到
        // 一个「非空却全被滤掉」的站点，只能手动一页页点）。
        final shouldContinue =
            _similarity > 0 && rawGrew && !visibleGrew && after.hasMore;
        if (!shouldContinue) return;
      }
    } finally {
      _autoPaging = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final searching = outcome != null && !outcome.finished;
    final hasKeyword = _controller.text.trim().isNotEmpty;
    // 落地页（搜索历史 + 热门推荐）只由**输入框**决定。
    //
    // 不能用「`outcome == null`」当条件（用户 2026-10-14 实测反馈）：
    // `_activeSearch` 是**跨页面存活**的状态，搜过一次后就一直存在，
    // 于是清空输入框、甚至切走再切回搜索页，都再也回不到推荐落地页。
    // 输入框为空 = 「还没开始搜」，就该看到推荐。（清空时同时会调用
    // `state.clearSearch()` 把残留结果丢掉，避免回到落地页后残留状态又在下一轮
    // 输入时冒出来。）
    final showLanding = !hasKeyword;

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInputRow(searching, hasKeyword, outcome != null),
              const SizedBox(height: AppSpace.md),
              if (searching)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpace.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Expanded(
                child: showLanding
                    ? _buildLanding()
                    : _buildResultsArea(outcome),
              ),
            ],
          ),
        ),
        // 联想下拉层：覆盖在输入框正下方。
        //
        // 必须包一层 `TextFieldTapRegion`：它把面板归入输入框的「点击区域组」，
        // 于是点面板不会被 `TextField.onTapOutside` 当成「点外部」——否则面板会
        // 在点击的落下与抬起之间被卸载，`ListTile.onTap` 永远收不到
        // （实测缺陷，用户 2026-10-14）。
        if (_suggestVisible && _suggestions != null)
          Positioned(
            top: AppSpace.lg + 56,
            left: AppSpace.lg,
            right: AppSpace.lg,
            child: TextFieldTapRegion(child: _buildSuggestPanel()),
          ),
      ],
    );
  }

  Widget _buildInputRow(bool searching, bool hasKeyword, bool hasOutcome) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('search-input'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '搜索影片',
              hintText: '输入片名后回车,或点击搜索',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => _submit(value),
            // 收起联想面板靠**点击外部**，而**不是**靠失焦。
            //
            // 为什么不能用 `_focusNode` 的失焦（实测缺陷，用户 2026-10-14：
            // 「点击联想结果没有反应也没有输入到输入框中」）：点击面板里的
            // `ListTile` 本身就会让输入框失焦，于是失焦处理先把面板卸载，
            // 点击的抬起事件就再也落不到那个 ListTile 上——`onTap` 永远不会触发。
            // 鼠标点击的按下/抬起跨越两帧，而 widget 测试的 down+up 在同一帧
            // 内完成，所以这个缺陷能躲过 widget 测试。
            onTapOutside: (_) {
              if (_suggestVisible) setState(() => _suggestVisible = false);
            },
          ),
        ),
        const SizedBox(width: AppSpace.md),
        _buildScopeButton(),
        const SizedBox(width: AppSpace.md),
        FilledButton.icon(
          onPressed: searching ? null : _submit,
          icon: const Icon(Icons.search),
          label: const Text('搜索'),
        ),
        const SizedBox(width: AppSpace.sm),
        OutlinedButton.icon(
          // 按钮在两种情形下都要**可用**（用户 2026-10-14：「取消按钮也没办法
          // 点击」）：
          // - 搜索在途 → 「取消」（丢掉在途批次，对齐上游可取消搜索）；
          // - 搜索已结束但还停在结果页 → 「返回推荐」（清空输入 + 清掉结果，
          //   回到搜索历史/热门推荐）。
          // 之前只写了 `searching ? cancel : null`，搜索一结束按钮就变灰，
          // 而那时恰好是用户最需要一个「回去」入口的时候。
          key: const ValueKey('search-cancel'),
          onPressed: searching
              ? _state.cancelSearch
              : (hasKeyword || hasOutcome ? _backToLanding : null),
          icon: Icon(
            searching ? Icons.cancel_outlined : Icons.arrow_back_outlined,
          ),
          label: Text(searching ? '取消' : '返回推荐'),
        ),
      ],
    );
  }

  /// 未搜索时的落地页：历史 + 热门推荐（上游 SearchFragment 的主界面）。
  ///
  /// 用 `Column` + `Expanded` 而不是整体 `ListView`：热门区要「按可用宽高恰好
  /// 铺满」，就必须拿到**有限的**高度约束（`LayoutBuilder` 在无限高的滚动列表里
  /// 只能得到 infinity）。因此历史区按自然高度、热门区吃掉剩下全部空间。
  Widget _buildLanding() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHistorySection(),
        const SizedBox(height: AppSpace.lg),
        Expanded(child: _buildHotSection()),
      ],
    );
  }

  /// 搜索历史：chips + 单条删除 + 全部清空。
  Widget _buildHistorySection() {
    final history = _state.recentSearchKeywords;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.history, size: 18),
            const SizedBox(width: AppSpace.sm),
            Text('搜索历史', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            if (history.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  await _state.clearSearchHistory();
                },
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('清空'),
              ),
          ],
        ),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
            child: Text(
              '暂无搜索记录',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final keyword in history)
                  InputChip(
                    key: ValueKey('search-history-$keyword'),
                    label: Text(keyword),
                    onPressed: () => _searchFrom(keyword),
                    onDeleted: () => _state.removeSearchKeyword(keyword),
                    deleteIconColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 热门推荐：类目 tab + **按可用宽高恰好铺满**的榜单海报卡片（360kan 榜单）。
  ///
  /// 为什么用卡片而不是词 chips（用户 2026-10-14：「能找到对应的图片吗？
  /// 显示成卡片是否更好看点」）：榜单接口本身就带竖版海报（`cover`）、集数
  /// （`upinfo`）与评分（`doubanscore`），词条把这三样全丢了。
  ///
  /// 为什么条数由布局算（用户 2026-10-14：「能否自动基于高宽计算显示多少个推荐
  /// 条目也就是刚好铺满的那种」）：固定 10 条时，窄窗口一行放 7 个就会出现
  /// 「第一行 7 个 + 第二行 3 个 + 右侧一大片空白」的半行。现在显示条数恒为
  /// `列 × 行`，由 `HotRankLayout` 从可用宽高算出；候选池取接口全量 30 条，
  /// 于是还能「换一批」轮换出一屏之外的条目。
  ///
  /// 点击语义**不是播放**：360kan 不是本应用可播放的站源，点卡片执行的是
  /// 「拿这个片名去各站点搜索」——与原来的词 chips 完全一致，只是换了呈现。
  Widget _buildHotSection() {
    final pool = _hotRanks[_hotTab] ?? const <SearchSuggestItem>[];
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = HotRankLayout.resolve(
          availableWidth: constraints.maxWidth,
          // 头部（标题行 + 类目 tab）占固定高度，网格只能用剩下的。头部被强制成
          // `_hotHeaderHeight`，这个减法才是精确的（否则多算/少算一行）。
          availableHeight: constraints.maxHeight - _hotHeaderHeight,
          poolSize: pool.length,
        );
        final window = hotRankWindow(
          pool,
          offset: _hotOffsets[_hotTab] ?? 0,
          count: layout.itemCount,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: _hotHeaderHeight, child: _buildHotHeader(layout)),
            Expanded(child: _buildHotGrid(layout, window)),
          ],
        );
      },
    );
  }

  /// 头部：标题 + 语义说明 + 「换一批」 + 类目 tab。
  Widget _buildHotHeader(HotRankLayout layout) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 24,
          child: Row(
            children: [
              const Icon(Icons.local_fire_department_outlined, size: 18),
              const SizedBox(width: AppSpace.sm),
              Text('热门推荐', style: theme.textTheme.titleSmall),
              const SizedBox(width: AppSpace.sm),
              // 必须写清楚点卡片是「搜」而不是「播」：卡片带海报很容易被当成
              // 可播条目（本页结果区确实点开即详情），不说明就会误导。
              Expanded(
                child: Text(
                  '点击卡片搜索该片名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 「换一批」：从候选池里轮换出**一屏之外**的条目。
              // 池子不比一屏大时换不出新内容，按钮直接不显示（而不是点了没反应）。
              if (layout.canShuffle)
                TextButton.icon(
                  key: const ValueKey('search-hot-shuffle'),
                  onPressed: () => _shuffleHot(layout),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('换一批'),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        SizedBox(
          height: 32,
          child: Row(
            children: [
              for (final category in HotRankCategory.values) ...[
                TagChip(
                  key: ValueKey('search-hot-tab-${category.name}'),
                  label: category.label,
                  selected: _hotTab == category,
                  onTap: () => setState(() => _hotTab = category),
                  selectable: true,
                ),
                const SizedBox(width: AppSpace.sm),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 网格：`columns × rows` 个卡片，恰好铺满可用空间。
  Widget _buildHotGrid(HotRankLayout layout, List<SearchSuggestItem> window) {
    final theme = Theme.of(context);
    if (window.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            '热门榜单加载失败或为空（断网时可稍后重试）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.zero,
      // 固定行高：铺满计算按 `HotRankMetrics.cardHeight` 算，这里必须用同一个值，
      // 否则算出来的行数与实际显示的行数会不一致（又出现半行/溢出）。
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: layout.columns,
        mainAxisExtent: HotRankMetrics.cardHeight,
        crossAxisSpacing: HotRankMetrics.spacing,
        mainAxisSpacing: HotRankMetrics.spacing,
      ),
      itemCount: window.length,
      itemBuilder: (context, index) {
        final item = window[index];
        return _PosterCard(
          key: ValueKey('search-hot-${_hotTab.name}-$index'),
          title: item.title,
          imageUrl: item.cover,
          subtitle: item.subtitle,
          rank: item.rank,
          score: item.score,
          onTap: () => _searchFrom(item.title),
        );
      },
    );
  }

  /// 换一批：把窗口在候选池里前移一屏（`hotRankWindow` 会回绕）。
  void _shuffleHot(HotRankLayout layout) {
    final current = _hotOffsets[_hotTab] ?? 0;
    setState(() => _hotOffsets[_hotTab] = current + layout.itemCount);
  }

  /// 联想下拉面板。
  Widget _buildSuggestPanel() {
    final items = _suggestions ?? const <SearchSuggestItem>[];
    return Material(
      elevation: 6,
      borderRadius: AppRadius.mdAll,
      // Material 的 borderRadius 只圆化自身背景，**不裁剪子控件**：不套
      // ClipRRect 时 ListView 的最后一行会画到圆角外面（实测下拉底部有方角残留）。
      child: ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppSpace.md),
                  child: Text('暂无联想词'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      key: ValueKey('search-suggest-$index'),
                      dense: true,
                      leading: const Icon(Icons.search, size: 16),
                      title: Text(item.title, maxLines: 1),
                      onTap: () => _searchFrom(item.title),
                    );
                  },
                ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 结果区
  // ---------------------------------------------------------------------------

  Widget _buildResultsArea(MultiSiteSearchOutcome? outcome) {
    if (outcome == null) {
      // 有关键字但还没触发搜索（例如输入了但没回车）。
      return const EmptyState(
        icon: Icons.manage_search_outlined,
        title: '输入关键词开始搜索',
        message: '结果会按站点分组显示，单个站点失败不影响其他站点。',
      );
    }
    if (outcome.cancelled) {
      return const EmptyState(icon: Icons.search_off_outlined, title: '搜索已取消');
    }
    if (outcome.results.isEmpty) {
      if (!outcome.finished) return const LoadingBlock();
      return EmptyState(
        icon: Icons.search_off_outlined,
        title: outcome.succeededCount == 0 && outcome.results.isEmpty
            ? outcome.scoped
                  ? '该范围内没有可搜索的站点'
                  : '当前配置没有可搜索的站点'
            : '没有搜索结果',
        message: outcome.succeededCount == 0 && outcome.results.isEmpty
            ? '或搜索已被取消。'
            : null,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSummary(outcome),
        const SizedBox(height: AppSpace.sm),
        _buildFilterBar(),
        const SizedBox(height: AppSpace.sm),
        Expanded(child: _buildSiteSplit()),
      ],
    );
  }

  Widget _buildSummary(MultiSiteSearchOutcome outcome) {
    final visibleTotal = _rawEntries.fold<int>(
      0,
      (sum, entry) => sum + _visibleOf(entry).length,
    );
    final parts = <String>[
      '“${outcome.keyword}”',
    ];
    if (outcome.siteKey.isNotEmpty) {
      parts.add('范围 站点：${_siteNameOf(outcome.siteKey) ?? outcome.siteKey}');
    } else if (outcome.group.isNotEmpty) {
      parts.add('范围 分组：${outcome.group}');
    }
    parts
      ..add('命中站点 ${outcome.succeededCount}/${outcome.results.length}')
      ..add('条目 $visibleTotal/${outcome.totalItems}');
    if (outcome.failedCount > 0) parts.add('失败 ${outcome.failedCount}');
    if (outcome.skippedUnsupported > 0) {
      parts.add('跳过不可运行站点 ${outcome.skippedUnsupported}');
    }
    if (outcome.skippedNotSearchable > 0) {
      parts.add('跳过不可搜索站点 ${outcome.skippedNotSearchable}');
    }
    if (outcome.cancelled) {
      parts.add('已取消');
    } else if (outcome.finished) {
      parts.add('耗时 ${outcome.totalElapsed.inMilliseconds}ms');
    } else {
      parts.add('搜索中…');
    }
    return Text(
      parts.join(' · '),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  /// 筛选条：分组 chips + 相似度（预设 chips + 自定义滑块）。
  Widget _buildFilterBar() {
    final groups = _resultGroups;
    final custom = !_similarityPresets.contains(_similarity);
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('分组:', style: TextStyle(fontWeight: FontWeight.w500)),
        TagChip(
          key: const ValueKey('search-group-all'),
          label: '全部',
          selected: _filterGroup.isEmpty,
          onTap: () => setState(() => _filterGroup = ''),
          selectable: true,
        ),
        for (final group in groups)
          TagChip(
            key: ValueKey('search-group-$group'),
            label: group,
            selected: _filterGroup == group,
            onTap: () => setState(() => _filterGroup = group),
            selectable: true,
          ),
        const SizedBox(width: AppSpace.md),
        const Text('相似度:', style: TextStyle(fontWeight: FontWeight.w500)),
        for (final value in _similarityPresets)
          TagChip(
            key: ValueKey('search-similarity-$value'),
            label: _similarityLabel(value),
            selected: _similarity == value,
            onTap: () => _applySimilarity(value),
            selectable: true,
          ),
        TagChip(
          key: const ValueKey('search-similarity-custom'),
          // 自定义档位时把当前值显示在 chip 上，否则默认文案是「自定义…」。
          label: custom ? '≥$_similarity%' : '自定义…',
          selected: custom,
          onTap: _openSimilaritySlider,
          selectable: true,
        ),
      ],
    );
  }

  String _similarityLabel(int value) => switch (value) {
    0 => '不限',
    100 => '精确',
    _ => '≥$value%',
  };

  Future<void> _applySimilarity(int value) async {
    setState(() => _similarity = value);
    await _state.setSearchSimilarity(value);
    if (!mounted) return;
    // 阈值升高可能把当前站点整页滤掉：主动续翻下一页找命中项。
    if (value > 0) unawaited(_loadMore(auto: true));
  }

  /// 相似度滑块对话框（对齐上游 `SliderNumberDialog`：0~100、步进 1、
  /// 实时显示数值 + 说明文字）。
  Future<void> _openSimilaritySlider() async {
    final value = await showSimilaritySliderDialog(
      context,
      current: _similarity,
    );
    if (value == null || !mounted) return;
    await _applySimilarity(value);
  }

  /// 站点拆分布局：左侧站点列表（全部 + 各站点）+ 右侧结果区。
  Widget _buildSiteSplit() {
    final entries = _rawEntries;
    if (entries.isEmpty) return _buildNoVisibleResults();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 200, child: _buildSiteList(entries)),
        const SizedBox(width: AppSpace.md),
        Expanded(child: _buildActiveResults()),
      ],
    );
  }

  /// 站点列表：全部 + 有原始条目的站点（点击切换右侧视图）。
  Widget _buildSiteList(List<SiteSearchEntry> entries) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        ListTile(
          key: const ValueKey('search-site-all'),
          dense: true,
          selected: _activeSiteKey == _allSitesKey,
          title: const Text('全部站点'),
          trailing: Text('${_allViewVods.length}'),
          onTap: () => _selectSite(_allSitesKey),
        ),
        for (final entry in entries)
          Builder(
            builder: (context) {
              final visible = _visibleOf(entry).length;
              return ListTile(
                key: ValueKey('search-site-${entry.siteKey}'),
                dense: true,
                selected: _activeSiteKey == entry.siteKey,
                title: Text(
                  entry.siteName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: entry.fromCache
                    ? const Text('缓存', style: TextStyle(fontSize: 11))
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 被相似度整站滤掉时给出显式标记：这类站点保留在侧栏里
                    // （否则用户无法选中它继续翻页找命中项）。
                    if (visible == 0 && entry.itemCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpace.xs),
                        child: Icon(
                          Icons.filter_alt_off_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    Text('$visible'),
                  ],
                ),
                onTap: () => _selectSite(entry.siteKey),
              );
            },
          ),
      ],
    );
  }

  void _selectSite(String siteKey) {
    setState(() => _activeSiteKey = siteKey);
    _scrollResultsToTop();
    // 选中一个「非空但被整页滤掉」的站点时，主动续翻下一页找命中项
    // （`auto: true` 带条件门槛，不会平白翻页）。
    if (siteKey != _allSitesKey) unawaited(_loadMore(auto: true));
  }

  /// 右侧结果：单站点平铺（带分页）或「全部」聚合平铺。
  Widget _buildActiveResults() {
    final active = _activeEntry;
    if (active == null) {
      // 「全部」视图：聚合各站点当前已加载的可见条目（上游同样不分页）。
      final vods = _allViewVods;
      if (vods.isEmpty) return _buildNoVisibleResults();
      return _buildResultPane(vods, footer: _buildAllViewPagingHint());
    }
    final visible = _visibleOf(active);
    final footer = _buildPagingFooter(active);
    if (visible.isEmpty) {
      return _buildResultPane(
        const [],
        footer: footer,
        placeholder: EmptyState(
          icon: Icons.filter_alt_off_outlined,
          title: '该站点当前筛选下没有可见结果',
          message: _similarity > 0
              ? '相似度阈值把这一页都过滤掉了，可放宽阈值或继续加载下一页。'
              : null,
        ),
      );
    }
    return _buildResultPane(visible, footer: footer);
  }

  /// 结果窗格：可滚动海报墙 + **固定在底部**的分页页脚。
  ///
  /// 页脚为什么不放进 `ListView`：`ListView(children:)` 是懒构建的，屏幕外的
  /// 页脚根本不会被创建（既无法断言，用户也得滚到底才知道能不能继续加载）。
  /// 固定在底部后，加载能力始终可见，自动预取仍然由滚动位置触发。
  Widget _buildResultPane(
    List<Vod> vods, {
    required Widget footer,
    Widget? placeholder,
  }) {
    final active = _activeEntry;
    return Column(
      children: [
        Expanded(
          child: vods.isEmpty
              ? (placeholder ?? const SizedBox.shrink())
              : ListView(
                  key: const ValueKey('search-result-list'),
                  controller: _resultScroll,
                  children: [
                    Wrap(
                      spacing: AppSpace.md,
                      runSpacing: AppSpace.md,
                      children: [
                        for (final vod in vods)
                          _buildResultCard(
                            vod,
                            active?.siteKey ?? _ownerSiteKeyOf(vod),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
        footer,
      ],
    );
  }

  /// 条目所属站点（「全部」视图里点开详情时需要知道用哪个站点取详情）。
  String _ownerSiteKeyOf(Vod vod) {
    for (final entry in _rawEntries) {
      if (entry.result?.list.any((item) => identical(item, vod)) ?? false) {
        return entry.siteKey;
      }
    }
    return '';
  }

  Widget _buildResultCard(Vod vod, String siteKey) {
    return _PosterCard(
      key: ValueKey('search-result-$siteKey-${vod.vodId}'),
      title: vod.vodName,
      imageUrl: vod.vodPic,
      subtitle: vod.vodRemarks,
      onTap: () async {
        final entry = _state.activeSearch?.entryOf(siteKey);
        if (entry != null) await _openResult(entry, vod);
      },
    );
  }

  /// 单站点视图的页脚：加载中 / 加载更多 / 已全部加载。
  Widget _buildPagingFooter(SiteSearchEntry entry) {
    final theme = Theme.of(context);
    if (entry.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpace.sm),
            Text('正在加载第 ${entry.page + 1} 页…'),
          ],
        ),
      );
    }
    if (entry.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: FilledButton.tonalIcon(
          key: const ValueKey('search-load-more'),
          onPressed: () => _loadMore(),
          icon: const Icon(Icons.expand_more),
          label: Text('加载更多（第 ${entry.page + 1} 页）'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
      child: Text(
        key: const ValueKey('search-no-more'),
        entry.pageCount > 0
            ? '已全部加载（${entry.page} 页 · ${entry.itemCount} 条）'
            : '已全部加载（${entry.itemCount} 条）',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 「全部」视图的页脚说明：分页只在单站点视图里提供（对齐上游）。
  Widget _buildAllViewPagingHint() => Padding(
    key: const ValueKey('search-all-paging-hint'),
    padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
    child: Text(
      '在左侧选择单个站点可继续加载下一页',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _buildNoVisibleResults() {
    final hasRaw = (_outcome?.totalItems ?? 0) > 0;
    return EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: hasRaw ? '当前筛选下没有可见结果' : '没有搜索结果',
      message: hasRaw
          ? '相似度阈值或分组筛选把全部结果过滤掉了，可放宽筛选再试。'
          : null,
    );
  }
}

/// 海报卡片：搜索结果与热门推荐**共用**（140×190 竖版海报 + 标题 + 副标题）。
///
/// 为什么抽成一个：两者在同一个页面上相邻出现（结果区 / 落地页热门区），
/// 各写一份必然分叉；而仓库已有的 `browse_pages._VodCard` 是私有且被网格
/// 约束（文字区用 `Expanded` 撑满格子），直接搬过来会带上网格专用行为。
///
/// 角标：`rank` / `score` 只有热门榜单会传（结果条目的元信息走副标题）。
class _PosterCard extends StatelessWidget {
  const _PosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.imageUrl,
    this.subtitle,
    this.rank,
    this.score,
  });

  static const double _width = 140;
  static const double _posterHeight = 190;

  final String title;
  final VoidCallback onTap;
  final String? imageUrl;
  final String? subtitle;

  /// 榜单名次角标（热门榜单用；搜索结果不传）。
  final int? rank;

  /// 评分角标（豆瓣分；榜单里多数条目为空）。
  final String? score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rank = this.rank;
    final score = this.score;
    return SizedBox(
      width: _width,
      // 卡片总高**固定**（用户 2026-10-14：「自动基于高宽计算… 刚好铺满」）：
      // 热门网格按 `mainAxisExtent` 恰好铺满，行高必须可预测；结果区（`Wrap`）
      // 里的卡片也因此各行列对齐，不再因有无副标题而高低不齐。
      height: HotRankMetrics.cardHeight,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdAll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: AppRadius.mdAll,
              child: Stack(
                children: [
                  PosterImage(
                    url: imageUrl,
                    width: _width,
                    height: _posterHeight,
                    // 限解码尺寸：榜单封面的原始分辨率从 150×200 到 770×1080
                    // 都有（最大那张 PNG 1.6MB）。按 2 倍屏解码已经够清晰，
                    // 再大只是白吃内存与解码时间。
                    cacheWidth: (_width * 2).round(),
                  ),
                  if (rank != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _CornerBadge(text: 'TOP$rank'),
                    ),
                  if (score != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _CornerBadge(text: score, highlight: true),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            // 文字区吃掉剩余高度；放大字号时**只缩不放**，避免固定高的卡片溢出。
            Expanded(
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 海报角标（与 `browse_pages` 的卡片角标同一视觉语言）。
class _CornerBadge extends StatelessWidget {
  const _CornerBadge({required this.text, this.highlight = false});

  final String text;

  /// 评分/名次用暖色强调（中性信息则用半黑底）。
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
/// 相似度滑块对话框（对齐上游安卓 `SliderNumberDialog`）。
///
/// 实现委托给共享的 [showNumberSliderDialog]：设置页的「搜索线程」是同一个
/// 交互形态（上游也是同一个对话框服务两处），两份实现必然分叉。
/// `keyPrefix` 保持 `similarity` 以免既有 widget 测试的 key 失效。
///
/// 返回用户确认的数值；取消时返回 null。
Future<int?> showSimilaritySliderDialog(
  BuildContext context, {
  required int current,
}) => showNumberSliderDialog(
  context,
  title: '相似度',
  current: current,
  minValue: 0,
  maxValue: 100,
  suffix: '%',
  hint: '调整搜索结果的匹配宽松度，100为精确匹配，0为不限',
  keyPrefix: 'similarity',
);
