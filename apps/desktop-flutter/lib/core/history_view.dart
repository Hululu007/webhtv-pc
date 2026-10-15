/// 历史记录相关的纯逻辑：详情页从历史恢复播放的解析。
///
/// 纯逻辑层：不依赖 Flutter，也不依赖 `dart:io`，也不依赖 `services/`。
/// 理由与 `hot_rank_layout.dart`、`search_result_filter.dart` 一致——线路三级
/// 匹配与「歧义就不猜」是本轮最容易写错的语义，必须在无窗口环境下可单测。
///
/// 因此 [resolveHistoryTarget] 收标量而不是 `PlaybackHistory`：后者定义在
/// `services/storage.dart`，收它会新开一条 `core/` → `services/` 的依赖方向。
library;

import 'protocol.dart';

/// 详情页从历史恢复播放的目标（`docs/phase6/design/02` §2）。
class HistoryResumeTarget {
  const HistoryResumeTarget({
    required this.flag,
    required this.episodeIndex,
    required this.episodeName,
    required this.matched,
  });

  /// 命中的线路 flag（展示用）。空串表示没有任何线路。
  final String flag;

  /// 该线路内剧集的**原始下标**（`VodPlayLine.episodes` 的下标）。
  ///
  /// 必须用原始下标：播放要的是它，而渲染下标经过季度过滤与倒序。
  final int episodeIndex;

  /// 命中的集名（用于按钮文案）。
  final String episodeName;

  /// 是否**完整**命中（线路与集都对上）。
  ///
  /// 只有完整命中才允许把按钮改成「继续播放」。
  final bool matched;

  /// 无历史时的目标：第一条线路第 0 集。
  factory HistoryResumeTarget.firstEpisodeOf(List<VodPlayLine> lines) {
    if (lines.isEmpty) {
      return const HistoryResumeTarget(
        flag: '',
        episodeIndex: 0,
        episodeName: '',
        matched: false,
      );
    }
    final first = lines.first;
    return HistoryResumeTarget(
      flag: first.flag,
      episodeIndex: 0,
      episodeName: first.episodes.isEmpty ? '' : first.episodes.first.name,
      matched: false,
    );
  }
}

/// 解析「用哪条线路、第几集」（`docs/phase6/design/02` §2.1、§2.2）。
///
/// 线路匹配三级顺序，任一级命中即返回；集匹配两级顺序。
/// **任何一级出现歧义都不猜**（对齐上游 `uniqueFlagForEpisodeUrl`）。
///
/// 收标量而不是 `PlaybackHistory`：后者在 `services/storage.dart`，
/// 而本模块属于纯逻辑层（`core/` 不得依赖 `services/`）。
HistoryResumeTarget resolveHistoryTarget({
  required String historyFlag,
  required String historyEpisodeId,
  required String historyEpisodeName,
  required List<VodPlayLine> lines,
}) {
  if (lines.isEmpty) return HistoryResumeTarget.firstEpisodeOf(lines);
  final hasHistory =
      historyFlag.isNotEmpty ||
      historyEpisodeId.isNotEmpty ||
      historyEpisodeName.isNotEmpty;
  if (!hasHistory) return HistoryResumeTarget.firstEpisodeOf(lines);

  // 第一级：flag 精确命中，且该线路**包含**这一集。
  for (final line in lines) {
    if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
    final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
    if (index >= 0) {
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第二级：集 URL 在所有线路里**唯一**命中。
  if (historyEpisodeId.isNotEmpty) {
    final hits = <(VodPlayLine, int)>[];
    for (final line in lines) {
      final index = _indexOfUrl(line, historyEpisodeId);
      if (index >= 0) hits.add((line, index));
    }
    if (hits.length == 1) {
      final (line, index) = hits.first;
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第三级：线路名命中——**仅当历史没有集入口目标**（旧数据）。
  //
  // 为什么必须加这个前提：历史带着集入口却一条线路都找不到时，说明那一集已
  // 从所有线路里消失，此时按线路名"猜"第 0 集会把用户送到错误的集上；按
  // 「歧义就不猜」退回第一条线路。只有历史**没有**集入口（`episodeId` 为空，
  // 旧数据）时，线路名命中才是可信的线路级命中。
  if (historyEpisodeId.isEmpty) {
    for (final line in lines) {
      if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
      final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index < 0 ? 0 : index,
        episodeName: index < 0
            ? (line.episodes.isEmpty ? '' : line.episodes.first.name)
            : line.episodes[index].name,
        // 线路命中但集没命中 → 不是完整命中。
        matched: false,
      );
    }
  }

  return HistoryResumeTarget.firstEpisodeOf(lines);
}

/// 在线路内定位历史那一集：URL 精确优先，集名兜底。
int _episodeIndexOf(VodPlayLine line, String episodeId, String episodeName) {
  if (episodeId.isNotEmpty) {
    final byUrl = _indexOfUrl(line, episodeId);
    if (byUrl >= 0) return byUrl;
  }
  if (episodeName.isNotEmpty) {
    for (var i = 0; i < line.episodes.length; i++) {
      if (line.episodes[i].name == episodeName) return i;
    }
  }
  return -1;
}

int _indexOfUrl(VodPlayLine line, String url) {
  for (var i = 0; i < line.episodes.length; i++) {
    if (line.episodes[i].url == url) return i;
  }
  return -1;
}

/// 详情页首屏按钮的文案（`docs/phase6/design/02` §3.1）。
///
/// 对齐上游 `TmdbDetailActivity#updatePlayLabel`：命中当前集**且**有进度
/// 才叫"继续播放"，否则是"播放第一集"。
///
/// 为什么用 `resumePosition` 而不是自己判断 `completed` 与位置阈值：
/// [AppState.resumePositionFor] 已经把这两件事一起处理了，两处判断会漂移。
String historyPlayLabel({
  required HistoryResumeTarget target,
  required Duration? resumePosition,
  String fallback = '播放第一集',
}) {
  if (!target.matched) return fallback;
  if (resumePosition == null) return fallback;
  if (target.episodeName.isEmpty) return fallback;
  return '继续播放 · ${target.episodeName}';
}

/// 历史页的三种模式。
enum HistoryViewMode {
  /// 默认：点卡片按「点击行为」设置分流。
  none,

  /// 长按进入的删除态：点卡片即删该条（对齐上游 `HistoryAdapter#setDelete`）。
  singleDelete,

  /// 「批量删除」按钮进入的多选态：点卡片切换勾选。
  multiSelect,
}

/// 不可变的历史页视图状态。
class HistoryViewState {
  const HistoryViewState({
    required this.mode,
    required this.selectedIds,
    required this.keyword,
  });

  /// 初始态。
  static const HistoryViewState initial = HistoryViewState(
    mode: HistoryViewMode.none,
    selectedIds: <int>{},
    keyword: '',
  );

  final HistoryViewMode mode;

  /// 已勾选的历史记录 id。仅 [HistoryViewMode.multiSelect] 有意义。
  final Set<int> selectedIds;

  /// **上一次已知的**搜索词。
  ///
  /// 它同时是 [withKeyword] 的比较基准：**任何**转移都不得重置它，
  /// 否则基准漂移会导致每次 `setState` 都清空用户的勾选。
  final String keyword;

  HistoryViewState copyWith({
    HistoryViewMode? mode,
    Set<int>? selectedIds,
    String? keyword,
  }) => HistoryViewState(
    mode: mode ?? this.mode,
    selectedIds: selectedIds ?? this.selectedIds,
    keyword: keyword ?? this.keyword,
  );

  /// 进入删除态（长按）。清空选中集——删除态没有"选中集"概念。
  HistoryViewState enterSingleDelete() =>
      copyWith(mode: HistoryViewMode.singleDelete, selectedIds: const <int>{});

  /// 进入多选态（批量删除按钮）。清空选中集，避免带上上一次的残留。
  HistoryViewState enterMultiSelect() =>
      copyWith(mode: HistoryViewMode.multiSelect, selectedIds: const <int>{});

  /// 退出到默认态。保留 [keyword]。
  HistoryViewState exitMode() =>
      copyWith(mode: HistoryViewMode.none, selectedIds: const <int>{});

  /// 切换某条记录的勾选。非多选态下**不产生**选中。
  HistoryViewState toggleSelection(int id) {
    if (mode != HistoryViewMode.multiSelect) return this;
    final next = <int>{...selectedIds};
    if (!next.remove(id)) next.add(id);
    return copyWith(selectedIds: next);
  }

  /// 全选：只勾选传入的**可见** id，不动已有的其他勾选。
  HistoryViewState selectAll(List<int> visibleIds) {
    if (mode != HistoryViewMode.multiSelect) return this;
    return copyWith(selectedIds: {...selectedIds, ...visibleIds});
  }

  /// 清空勾选。
  HistoryViewState clearSelection() =>
      copyWith(selectedIds: const <int>{});

  /// 更新搜索词。**变化时清空勾选**，未变化时返回同一实例。
  ///
  /// 为什么变化时必须清空：用户可能在多选态下搜索缩小范围，此时已勾选但
  /// **已不可见**的条目若仍留在 [selectedIds] 里，点「删除选中(N)」会删掉
  /// 用户看不见的条目。
  ///
  /// 为什么未变化时必须返回 `this`：调用方在 `setState` 里无条件调它，
  /// 每次都返回新实例会让用户刚勾的项被清空。
  HistoryViewState withKeyword(String next) {
    if (next == keyword) return this;
    return copyWith(keyword: next, selectedIds: const <int>{});
  }

  /// 是否可以执行批量删除。
  bool get canDeleteSelected =>
      mode == HistoryViewMode.multiSelect && selectedIds.isNotEmpty;

  /// 已勾选的 id，**升序**。稳定顺序便于测试断言与"全选"的幂等性。
  List<int> get selectedInOrder => selectedIds.toList()..sort();
}

/// 「点击历史记录」的行为（`docs/phase6/design/01` §4.1）。
///
/// 存字符串而不是 enum：本层是纯逻辑层，且要与 `settings.json` 的
/// 字面值一一对应（与 `UiThemeMode` 同样的分层理由）。
abstract final class UiHistoryClickAction {
  /// 打开该条对应的详情页（默认）。
  static const String detail = 'detail';

  /// 直接续播（既有行为）。
  static const String play = 'play';

  static const List<String> values = [detail, play];

  /// 把任意输入归一化成合法值；不认识的值回落到默认 [detail]。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : detail;
  }
}
