/// 跨源历史续播：在**当前播放源**内找一个能接上的站点，并把进度迁移过去。
///
/// 对应上游安卓 `HistoryResumeCoordinator` + `VodSourceResolver`
/// （`docs/global-history-resume-design.md` §11、§14），按用户 2026-10-27 的
/// 决定做了两处**刻意的收窄**：
///
/// 1. **绝不切换当前配置**：找不到可替代站点时只提示用户手动切源，
///    不擅自 `activateConfigRecord`（那会把用户整个 App 弹到另一个源上）。
/// 2. **不静默失败**：解析不出目标时给出可执行的动作（打开全局搜索 / 切源），
///    而不是像 v7 那样只弹一句「站点已不在当前配置中」就结束。
///
/// ## 两条路径
///
/// | 入口 | 行为 |
/// | --- | --- |
/// | 该记录所属站点**仍在当前配置**里 | 直接走既有续播（切站点 → 解析 → 播放），进度用原记录 |
/// | 站点已不在当前配置 | 按 TMDB / 片名在当前源内找可替代站点 → 迁移进度 → 播放 |
///
/// 第二条路径找不到高置信候选时**不自动播放**，而是让用户选：
/// 「打开全局搜索」或「取消」。这是「宁可不续播，不可错续播」的落地
/// （`docs/phase6/design/01` §4.1）。
library;

import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/resume_matching.dart';
import '../core/resume_migration.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'browse_pages.dart';
import 'history_resume_seed.dart';
import 'search_page.dart';

/// 从一条**非当前源**的历史恢复播放。
Future<void> openHistoryFromOtherSource(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
) async {
  final config = state.config;
  if (config == null || config.sites.isEmpty) {
    _toast(context, '当前没有生效的播放源配置，无法续播');
    return;
  }

  // ── 路径一：原站点仍在当前配置里 → 直接续播（进度不需要迁移） ──
  final sameSite = config.sites
      .where((candidate) => candidate.key == item.siteKey)
      .firstOrNull;
  if (sameSite != null) {
    await _playOnSite(context, state, item, sameSite, item.episodeName);
    return;
  }

  // ── 路径二：原站点不在了 → 在当前源内找可替代站点 ──
  //
  // 搜索只在**当前配置**的站点里发（用户决定 3：不切源），因此这里不需要
  // 处理「跨配置搜索」的竞态。
  final sites = [
    for (final site in config.sites)
      if (!site.hide && site.searchable) site,
  ];
  if (sites.isEmpty) {
    _toast(context, '当前播放源没有可搜索的站点，请切换播放源后重试');
    return;
  }

  final keyword = _searchKeywordOf(item);
  if (keyword.isEmpty) {
    _toast(context, '该记录缺少片名，无法在当前源中匹配：${item.vodName}');
    return;
  }

  final request = ResumeRequest(
    vodName: item.vodName,
    vodYear: item.vodYear,
    tmdbId: item.tmdbId,
    mediaType: item.mediaType,
  );

  // 加载态不可自动消失的 Toast 在这里不适用（桌面端用对话框），
  // 但必须让用户知道「正在找」，否则搜索 20s 期间界面像卡死。
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      duration: Duration(seconds: 20),
      content: Text('该记录不在当前播放源，正在当前源中匹配可续播站点…'),
    ),
  );
  try {
    final outcome = await state.searchAll(
      keyword,
      timeout: const Duration(seconds: 12),
    );
    messenger.hideCurrentSnackBar();
    if (!context.mounted) return;

    final candidates = <ResumeCandidate>[
      for (final entry in outcome.results)
        if (entry.succeeded)
          for (final vod in entry.result!.list.take(4))
            ResumeCandidate(
              siteKey: entry.siteKey,
              siteName: entry.siteName,
              vodId: vod.vodId,
              vodName: vod.vodName,
              vodYear: vod.vodYear?.trim() ?? '',
              episodeCount: 0,
              // 详情尚未加载，此刻只知道「搜索结果里有这一条」；
              // 目标集是否存在要等加载详情后再判定（见 _playOnSite）。
              hasTargetEpisode: true,
            ),
    ];
    if (candidates.isEmpty) {
      _toast(context, '未在当前播放源中找到「${item.vodName}」');
      if (context.mounted) await _offerGlobalSearch(context, state, item);
      return;
    }

    final ranked = rankCandidates(request, candidates);
    final pick = pickAutoPlayable(ranked);
    if (pick != null) {
      final site = config.sites
          .where((candidate) => candidate.key == pick.siteKey)
          .firstOrNull;
      if (site != null) {
        await _playOnSite(
          context,
          state,
          item,
          site,
          item.episodeName,
          vodIdOverride: pick.vodId,
          vodNameOverride: pick.vodName,
        );
        return;
      }
    }
    // 没有高置信候选：让用户自己选，不猜。
    if (context.mounted) await _offerGlobalSearch(context, state, item);
  } catch (error) {
    messenger.hideCurrentSnackBar();
    if (context.mounted) _toast(context, '自动匹配失败：$error');
  }
}

/// 在指定站点上解析并播放（公共尾部）。
///
/// [vodIdOverride] / [vodNameOverride] 用于「换到了另一个站点的同名作品」：
/// 此时详情要用新条目的 id，但**进度仍来自原记录**（见 [ResumePositionPolicy]）。
Future<void> _playOnSite(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
  Site site,
  String episodeName, {
  String? vodIdOverride,
  String? vodNameOverride,
}) async {
  if (!context.mounted) return;
  await state.selectSite(site);
  if (!context.mounted) return;
  final vodId = vodIdOverride ?? item.vodId;
  final vodName = vodNameOverride ?? item.vodName;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(
        state: state,
        vod: Vod(vodId: vodId, vodName: vodName, vodPic: item.vodPic),
        // 线路与集入口取自**原记录**：它们指向的是原源里的那一集，
        // 详情页找不到时会按「歧义就不猜」退回第一条线路（既有语义），
        // 不会把用户送到错误的集上。
        historyFlag: item.flag,
        historyEpisodeId: item.episodeId,
        // 进度必须一起带过去：跨源时详情页按当前站点查不到本机历史，
        // 少了它就只能从头播（用户点「继续观看」的意图被丢掉）。
        resumeSeed: resumeSeedOf(item),
      ),
    ),
  );
}

/// 搜索关键词：优先用片名本身（站点的搜索接口认片名，不认已清洗的标题）。
///
/// 为什么先原生片名再清洗：安卓 §10.3 的优先级是「规范标题 → 缓存标题 →
/// 原片名 → 去噪标题」，但 PC 侧此处**没有** TMDB 缓存可用（跨源时原源的
/// TMDB 绑定属于另一个 `config_id`），而站点的搜索接口对原片名的召回率
/// 最高。清洗只在原片名为空时兜底。
String _searchKeywordOf(PlaybackHistory item) {
  final raw = item.vodName.trim();
  if (raw.isNotEmpty) return raw;
  return '';
}

/// 降级入口：打开全局搜索，并带上「继续观看」上下文。
Future<void> _offerGlobalSearch(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
) async {
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('history-cross-source-dialog'),
      title: const Text('未找到可可靠续播的播放源'),
      content: Text(
        '「${item.vodName}」不在当前播放源中，且没有高置信的同名站点。\n'
        '可以打开全局搜索手动选择来源；进度会在选中后按同一集迁移。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('history-cross-source-open-search'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('打开全局搜索'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SearchPage(
        state: state,
        initialKeyword: _searchKeywordOf(item),
      ),
    ),
  );
}

void _toast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}
