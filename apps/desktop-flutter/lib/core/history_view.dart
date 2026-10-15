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
