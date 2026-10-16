/// 最近观看与收藏页（§17.2 历史页 / 收藏页，§15）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../services/proxy_server.dart';
import '../services/storage.dart';
import '../services/tmdb_history.dart';
import '../state/app_state.dart';
import '../core/protocol.dart';
import 'app.dart';
import 'common.dart';
import 'player_page.dart';
import 'tokens.dart';

/// 历史卡片的目标列宽。
///
/// 与首页海报墙（`browse_pages.dart` 的 `_poster*`）是**同一套尺度**：
/// `DESIGN.md` 的「内容网格」写明全站共用「目标列宽 150px、列间距 14px、
/// 网格内边距 16px、海报下方文字区高 40px」。首页那份是文件私有常量，这里
/// 只能各自声明——**改动时必须两处一起改**，否则两块海报墙的尺度会分叉。
const double _historyCardTargetWidth = 150;

/// 历史卡片列间距（= 首页海报墙的列间距，见上）。
const double _historyCardSpacing = 14;

/// 历史卡片海报下方的文字区高度（片名 + 集名两行）。
///
/// 给死高度而不是让它自适应：格子高度由「海报 2:3 + 本值」精确算出，文字区
/// 一旦浮动，海报就会被压成非 2:3（与首页 `_posterCaptionHeight` 同理）。
const double _historyCaptionHeight = 40;

/// 文字区允许的**最大**放大倍数（无障碍字号只缩不放）。
///
/// 与首页 `_VodCard` 同值同理由：文字区是固定高度，放大时不让步就会溢出格子。
const double _historyTextScaleMax = 1.25;

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.state});

  final AppState state;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _keyword = '';

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_repairMissingPosters());
    });
  }

  List<PlaybackHistory> get _items => _keyword.isEmpty
      ? _state.recentHistory()
      : _state.searchHistory(_keyword);

  /// 旧版本历史没有保存海报：打开历史页时按 vod_id 后台补齐，避免用户看到一屏
  /// 破图占位。只处理前 12 条且按作品去重，不阻塞历史页首帧。
  Future<void> _repairMissingPosters() async {
    final service = _state.siteService;
    final config = _state.config;
    if (service == null || config == null) return;
    final candidates = <PlaybackHistory>[];
    final seen = <String>{};
    for (final item in _items) {
      if (item.vodPic != null && item.vodPic!.trim().isNotEmpty) continue;
      final key = '${item.siteKey}@@@${item.vodId}';
      if (seen.add(key)) candidates.add(item);
      if (candidates.length >= 12) break;
    }
    var changed = false;
    for (final item in candidates) {
      Site? site;
      for (final candidate in config.sites) {
        if (candidate.key == item.siteKey) {
          site = candidate;
          break;
        }
      }
      if (site == null) continue;
      try {
        final parent = Vod(
          vodId: item.vodId,
          vodName: item.vodName,
          vodTag: item.vodId.startsWith('atvp_detail:') ? 'folder' : null,
        );
        final result = parent.isFolder
            ? await service.folderDetail(site, parent)
            : await service.detail(site, item.vodId);
        if (result.value.list.isEmpty) continue;
        final poster = result.value.list.first.vodPic;
        if (poster == null || poster.trim().isEmpty) continue;
        _state.updateHistoryPoster(item, poster);
        changed = true;
      } catch (_) {
        // 单条旧记录补图失败不影响历史列表和继续播放。
      }
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索片名或剧集名',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _keyword = value.trim()),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('清空播放历史'),
                      content: const Text('该操作只清空播放历史，不会删除配置。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    _state.clearHistory();
                    if (mounted) setState(() {});
                  }
                },
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清空历史'),
              ),
            ],
          ),
        ),
        if (_state.database == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('本地存储不可用，播放历史暂不记录。'),
          ),
        const Divider(height: 1),
        // 季度历史卡片（`02` §7.1）：同一节目的每季一张卡片。
        // 删除语义按 §7.4 分级：删季度卡片不删同节目其他季度；
        // 「删除整部节目」是独立二级操作，需二次确认。
        if (_state.seasonHistoryCards().isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('季度进度'),
          ),
          for (final card in _state.seasonHistoryCards())
            ListTile(
              key: ValueKey('season-card-${card.displayKey}'),
              dense: true,
              leading: const Icon(Icons.playlist_play),
              title: Text(
                '${card.identity?.key ?? '?'} · ${card.seasonLabel} · '
                '第 ${card.episodeNumber} 集',
              ),
              subtitle: Text(
                '${card.representative.sourceEpisodeName} · '
                '${card.progressPercent}% · 来源 ${card.representative.sourceFlag}'
                '${card.sources.length > 1 ? ' （共 ${card.sources.length} 个来源）' : ''}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '删除该季度进度（不影响同节目其他季度）',
                    onPressed: () {
                      final identity = card.identity;
                      if (identity == null) return;
                      _state.deleteSeasonProgress(
                        media: identity,
                        seasonNumber: card.seasonNumber,
                      );
                      setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                  IconButton(
                    tooltip: '删除整部节目的全部季度进度（二级操作）',
                    onPressed: () => _confirmDeleteMedia(card),
                    icon: const Icon(Icons.delete_forever_outlined, size: 18),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
        ],
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.history_outlined,
                  title: '暂无播放记录',
                  message: '播放任意剧集后会自动记录进度。',
                )
              // 列数必须由**内容区**宽度推出，而不是 `MediaQuery` 的整窗宽：
              // 壳层左侧有 `NavigationRail`(76) + `VerticalDivider`(1)，整窗宽
              // 会比内容区宽 77px，列数就会比首页海报墙多算（`design/01` §2.2
              // 要求两处共用同一套尺度）。
              : LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    key: const ValueKey('history-grid'),
                    padding: const EdgeInsets.all(AppSpace.lg),
                    gridDelegate: _historyGridDelegate(constraints.maxWidth),
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _buildHistoryCard(context, items[index]),
                  ),
                ),
        ),
      ],
    );
  }

  /// 网格度量：与首页海报墙同一套算法（`browse_pages.dart#_gridDelegate`）。
  ///
  /// 为什么不用 `SliverGridDelegateWithMaxCrossAxisExtent`：它的
  /// `mainAxisExtent` 是固定值，窗口变窄时列宽变小、高度不变，海报会被
  /// 压成非 2:3 或被裁切。这里列宽已知，格子高度就能精确算成
  /// 「海报 2:3 + 文字区」。
  static SliverGridDelegate _historyGridDelegate(double maxWidth) {
    final usable = maxWidth - AppSpace.lg * 2;
    final columns = (usable / (_historyCardTargetWidth + _historyCardSpacing))
        .round()
        .clamp(2, 12);
    final cellWidth = (usable - (columns - 1) * _historyCardSpacing) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _historyCardSpacing,
      mainAxisSpacing: AppSpace.sm,
      mainAxisExtent: cellWidth * 1.5 + AppSpace.sm + _historyCaptionHeight,
    );
  }

  /// 单张历史卡片（对齐上游 `res/layout/adapter_vod.xml`）。
  ///
  /// **片名只渲染一次 `Text`**：`integration_test/phase5_sync_flow_test.dart`
  /// 按 `find.text(name)` 断言 `findsOneWidget`。`Tooltip` 的 `message` 是字符串、
  /// 不产生 `Text`，但这里仍然不加 tooltip——片名与集名已各占一行。
  Widget _buildHistoryCard(BuildContext context, PlaybackHistory item) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('history-row-${item.id}'),
      onTap: () => _onCardTap(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `AspectRatio` 保证海报 2:3：文字区再高也不会把海报压变形。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: item.vodPic),
                  // 左下角进度角标（对齐上游 `@id/playback`）。
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: _HistoryBadge(
                      text: item.completed
                          ? '已看完'
                          : '已看 ${item.progressPercent}%',
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 2px 进度条紧贴海报下沿（对齐上游 `@id/progress`）。
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: LinearProgressIndicator(
              value: item.progress,
              minHeight: 2,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          // 文字区与首页 `_VodCard` 同形：`Expanded` + 夹住缩放。
          // `Expanded` 把文字区钉在固定高度上（格子高度已由 `mainAxisExtent`
          // 算死），海报 2:3 不受文字影响。
          //
          // 字号/行高也**照抄首页 `_VodCard`**（13/1.2 与 11/1.2，而不是 M3 默认的
          // 14/1.43 与 12/1.33）：这不是为了「好看」，是 1.25 倍 clamp 能不能成立
          // 的算术前提——40px 文字区在 1.25 倍下只放得下 32px 的本征高度，
          // M3 默认两行要 35.98px（×1.25 = 44.98px，溢出 5px，已实测）。
          // 首页那套 28.8px（×1.25 = 36px）才留得住 4px 余量；两者不一致会让
          // 「同一套尺度」名存实亡（`design/01` §2.2 第 1 条要求取值一致）。
          Expanded(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _historyTextScaleMax,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    item.vodName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  Text(
                    item.episodeName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片点击（Task 8 会按设置分流；此处先保持既有行为）。
  void _onCardTap(PlaybackHistory item) => unawaited(_resume(item));

  /// 「删除整部节目」二级操作（`02` §7.4）：必须先明确告知将删除的季度数量。
  Future<void> _confirmDeleteMedia(SeasonHistoryCard card) async {
    final identity = card.identity;
    if (identity == null) return;
    final count = _state.seasonProgressFor(identity).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('season-delete-media-confirm'),
        title: const Text('删除整部节目的播放进度'),
        content: Text(
          '将删除「${identity.key}」下全部 $count 个季度的播放进度。\n'
          '该操作不可撤销；同季度的其他来源也会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('season-delete-media-confirm-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除全部'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _state.deleteMediaProgress(identity);
    if (mounted) setState(() {});
  }

  /// 把旧版本保存的本地代理地址还原成站点入口目标。
  ///
  /// 旧记录可能把 `http://127.0.0.1:<port>/p/<token>/<base64>` 写进了
  /// `episode_id`。token 已失效，但路径最后一段仍包含原始站点目标，可以无损恢复。
  String _historyEntryTarget(PlaybackHistory item) =>
      restoreHistoryPlaybackTarget(item.episodeId);

  /// 从历史恢复播放。
  ///
  /// 设计约束：历史只保存剧集地址与站点 key，恢复时需要重新解析播放决策，
  /// 避免把过期直链直接交给播放器（§15.2 “继续播放”）。
  Future<void> _resume(PlaybackHistory item) async {
    final state = _state;
    final episodeTarget = _historyEntryTarget(item);
    final result = state.config;
    final site = result?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('该记录所属站点已不在当前配置中：${item.siteKey}')),
      );
      return;
    }
    await state.selectSite(site);
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: episodeTarget,
        flag: item.flag,
        vodId: item.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '历史记录没有可用播放地址',
          detail: episodeTarget,
        );
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              // 续播后再次写进度时必须保留**同一个入口目标**，否则这一条历史会
              // 被刚解析出的可播地址覆盖，下一次续播又失败。
              episodeTarget: episodeTarget,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: item.vodName,
              siteKey: item.siteKey,
              vodId: item.vodId,
              vodName: item.vodName,
              episodeName: item.episodeName,
              flag: item.flag,
              startPosition: Duration(milliseconds: item.positionMs),
              vodPic: item.vodPic,
              // 外挂字幕（§10.3）/弹幕（§21 Phase 3）：历史恢复同样带入。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
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
}

/// 海报左下角的进度角标（对齐上游 `@id/playback` 的半透明底胶囊）。
///
/// 底色取 `colorScheme.surface` 而不是写死黑：海报画面色彩不可控，而这里的
/// 文字用主题的 `labelSmall`，底与字必须成对取自同一主题才不会在亮色主题下
/// 变成「深底深字」。
class _HistoryBadge extends StatelessWidget {
  const _HistoryBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.favorites();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text(
                '收藏（${items.length}）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              const Text('收藏站点、影片或分组；数据保存在本地数据库。'),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.bookmark_border,
                  title: '暂无收藏',
                  message: '在详情页右上角可以收藏影片。',
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.kind == 'vod'
                            ? Icons.movie_outlined
                            : Icons.dns_outlined,
                      ),
                      title: Text(item.title),
                      subtitle: Text(
                        '类型=${item.kind} 站点=${item.siteKey} '
                        '目标=${item.targetId}'
                        '${item.subtitle == null ? "" : " · ${item.subtitle}"}',
                      ),
                      trailing: IconButton(
                        tooltip: '取消收藏',
                        onPressed: () {
                          state.database?.removeFavorite(
                            kind: item.kind,
                            siteKey: item.siteKey,
                            targetId: item.targetId,
                          );
                          (context as Element).markNeedsBuild();
                        },
                        icon: const Icon(Icons.bookmark_remove_outlined),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 本地实现的 firstOrNull，避免为单个用法引入 `package:collection`。
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}

/// 兼容旧版本把本地代理地址写进历史记录的情况。
String restoreHistoryPlaybackTarget(String episodeId) {
  final uri = Uri.tryParse(episodeId);
  if (uri != null && uri.path.startsWith(LocalProxyServer.pathPrefix)) {
    final encoded = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final decoded = LocalProxyServer.decodeTarget(encoded);
    if (decoded != null) return decoded.toString();
  }
  return episodeId;
}

/// 便于测试与诊断：把历史列表渲染成纯文本。
String describeHistory(List<PlaybackHistory> items) => items
    .map(
      (item) =>
          '${item.vodName} | ${item.episodeName} | ${item.progressPercent}% | '
          '${item.completed ? "completed" : "in-progress"}',
    )
    .join('\n');

/// 保持对 [AppError] 的显式引用，便于本文件单独测试错误提示。
String describeHistoryError(AppError error) => error.userMessage;
