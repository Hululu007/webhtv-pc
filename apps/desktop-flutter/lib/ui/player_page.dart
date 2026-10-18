/// 播放器页（§17.3）。
///
/// 包含：播放器画面、标题、线路选择、剧集列表、播放/暂停、进度条、音量、倍速、
/// 全屏、上一集/下一集、加载状态、错误提示，以及键盘快捷键（§10.3、§17.4）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/danmaku.dart';
import '../core/protocol.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/subtitle.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/danmaku_service.dart';
import '../services/live_danmaku_session.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'common.dart';
import 'danmaku_overlay.dart';
import 'player_controller.dart';
import 'tokens.dart';

/// 一次播放请求（由详情页或命令行构造）。
class PlaybackRequest {
  const PlaybackRequest({
    required this.url,
    required this.title,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.episodeName,
    required this.flag,
    String? playbackFlag,
    String? episodeTarget,
    this.headers = const {},
    this.startPosition,
    this.playLines = const [],
    this.episodeIndex = 0,
    this.vodPic,
    this.directUrl = false,
    this.subtitles = const [],
    this.subtitleHeaders = const {},
    this.danmaku = const [],
    this.tmdb,
  }) : episodeTarget = episodeTarget ?? url,
       playbackFlag = playbackFlag ?? flag;

  final String url;
  final String title;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String flag;
  final String playbackFlag;
  final Map<String, String> headers;
  final Duration? startPosition;

  /// 站点播放入口的**输入目标**（详情 `vod_play_url` 里该集 `$` 之后的值）。
  ///
  /// 与 [url] 的区别很关键：
  /// - [url] 是**解析后的可播地址**（T4 站点还要再经本地代理换成 `127.0.0.1/p/<token>/…`），
  ///   带时效签名，**不能**当作再次解析的输入；
  /// - [episodeTarget] 是站点能认的原始目标（网盘站是分享链，普通站是剧集地址）。
  ///
  /// 历史续播必须用 [episodeTarget] 重新解析：拿 [url] 去问站点只会得到
  /// 「站点返回业务错误」（用户反馈 2026-10-09「无法从历史记录页面继续播放」）。
  /// 为空时回退到 [url]（兼容命令行/直播等无需二次解析的场景）。
  final String episodeTarget;

  /// 播放结果携带的外挂字幕（§10.3）。
  final List<SubtitleInfo> subtitles;

  /// 拉取外挂字幕时使用的 Header（与媒体一致，含 Referer/UA/Cookie）。
  ///
  /// 与 [headers] 分开：走本地代理时 [headers] 被清空（由代理注入），而字幕由
  /// 宿主自己请求，必须用代理前的原始 Header（§11.3.1）。
  final Map<String, String> subtitleHeaders;

  /// 播放结果携带的弹幕源（§21 Phase 3）。拉取弹幕同样使用 [subtitleHeaders]。
  final List<DanmakuSource> danmaku;

  /// TMDB 季度身份（`docs/phase4/design/04` §8.1）。
  ///
  /// 为 `null` 时表示未携带季度身份（历史恢复、直播、命令行），
  /// 此时只写来源 `history`，不写季度进度（`02` §6.2）。
  final TmdbPlaybackIdentity? tmdb;

  /// 详情页给出的全部线路，用于线路切换与上下集。
  final List<VodPlayLine> playLines;
  final int episodeIndex;
  final String? vodPic;

  /// 地址已是最终可播地址（直播频道），无需经站点播放入口解析。
  ///
  /// 直播源的 `urls` 直接在本地就是媒体地址，走解析器只会多余地请求站点；
  /// 同时直播需要「失败按顺序切线路」（§13.3），与点播的剧集切换语义不同。
  final bool directUrl;

  PlaybackRequest copyWith({
    String? url,
    String? episodeTarget,
    String? episodeName,
    String? flag,
    String? playbackFlag,
    Map<String, String>? headers,
    int? episodeIndex,
    Duration? startPosition,
    bool clearStartPosition = false,
    List<SubtitleInfo>? subtitles,
    List<DanmakuSource>? danmaku,
  }) {
    return PlaybackRequest(
      url: url ?? this.url,
      // `episodeTarget` **不随 `url` 自动跟随**：两者语义不同（前者是站点入口
      // 目标、后者是解析后的可播地址），若换 `url` 时把入口目标也顶成播放地址，
      // 历史里存的就又是站点认不了的值。换集的调用点必须**显式**传 `episodeTarget`。
      episodeTarget: episodeTarget ?? this.episodeTarget,
      title: title,
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName ?? this.episodeName,
      flag: flag ?? this.flag,
      playbackFlag: playbackFlag ?? this.playbackFlag,
      headers: headers ?? this.headers,
      startPosition: clearStartPosition
          ? null
          : (startPosition ?? this.startPosition),
      playLines: playLines,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      vodPic: vodPic,
      directUrl: directUrl,
      subtitles: subtitles ?? this.subtitles,
      subtitleHeaders: subtitleHeaders,
      danmaku: danmaku ?? this.danmaku,
      tmdb: tmdb,
    );
  }
}

/// 画面显示模式：保留原始比例、裁切铺满、拉伸填充或固定常用比例。
///
/// 这些模式直接映射到 media_kit_video 的 [BoxFit] / [Video.aspectRatio]，
/// 不改变媒体流本身，只改变窗口内的显示方式。
enum PlayerGestureAction { toggleControls, enterFullscreen, togglePlayback }

PlayerGestureAction resolvePlayerGesture({
  required bool doubleTap,
  required bool fullscreen,
}) {
  if (!doubleTap) return PlayerGestureAction.toggleControls;
  return fullscreen
      ? PlayerGestureAction.togglePlayback
      : PlayerGestureAction.enterFullscreen;
}

enum PlayerVideoFitMode {
  contain('原始比例', BoxFit.contain, null),
  cover('裁切铺满', BoxFit.cover, null),
  fill('拉伸填充', BoxFit.fill, null),
  ratio16x9('固定 16:9', BoxFit.contain, 16 / 9),
  ratio4x3('固定 4:3', BoxFit.contain, 4 / 3);

  const PlayerVideoFitMode(this.label, this.fit, this.aspectRatio);

  final String label;
  final BoxFit fit;
  final double? aspectRatio;
}

/// 字幕显示样式：默认透明底 + 黑色描边，避免视频上出现整块黑色背景。
class PlayerSubtitleStyle {
  const PlayerSubtitleStyle({
    this.color = Colors.white,
    this.backgroundColor = Colors.black,
    this.backgroundOpacity = 0,
    this.outlineWidth = 2,
    this.textScale = 1,
    this.bottomPadding = 24,
  });

  final Color color;
  final Color backgroundColor;
  final double backgroundOpacity;
  final double outlineWidth;
  final double textScale;
  final double bottomPadding;

  PlayerSubtitleStyle copyWith({
    Color? color,
    Color? backgroundColor,
    double? backgroundOpacity,
    double? outlineWidth,
    double? textScale,
    double? bottomPadding,
  }) => PlayerSubtitleStyle(
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    outlineWidth: outlineWidth ?? this.outlineWidth,
    textScale: textScale ?? this.textScale,
    bottomPadding: bottomPadding ?? this.bottomPadding,
  );

  List<Shadow> get shadows {
    if (outlineWidth <= 0) return const [];
    final d = outlineWidth.clamp(0.5, 4.0).toDouble();
    return [
      for (final offset in [
        Offset(-d, -d),
        Offset(0, -d),
        Offset(d, -d),
        Offset(-d, 0),
        Offset(d, 0),
        Offset(-d, d),
        Offset(0, d),
        Offset(d, d),
      ])
        Shadow(color: Colors.black, offset: offset, blurRadius: 0),
    ];
  }

  SubtitleViewConfiguration get configuration => SubtitleViewConfiguration(
    style: TextStyle(
      height: 1.35,
      fontSize: 32 * textScale,
      color: color,
      fontWeight: FontWeight.w500,
      backgroundColor: backgroundColor.withValues(alpha: backgroundOpacity),
      shadows: shadows,
    ),
    textAlign: TextAlign.center,
    padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
  );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.state,
    required this.request,
    this.danmakuLoader,
  });

  final AppState state;
  final PlaybackRequest request;

  /// 弹幕加载器；测试可注入替身，默认自建 [DanmakuService]。
  final DanmakuLoader? danmakuLoader;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
  late final PlayerController _controller;
  late PlaybackRequest _request;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _saveTimer;
  Timer? _controlHideTimer;
  String? _loadError;

  /// 连播单次守卫（`design/03` §4.1 D1）。
  ///
  /// 一次连播未完成时忽略后续所有控制器通知，避免「一次播完连跳多集」。
  bool _advanceInFlight = false;

  /// 最近一次字幕错误提示是否已展示，避免每次 setState 重复弹提示。
  String? _lastShownSubtitleError;

  // ---------------------------------------------------------------- 弹幕

  /// 弹幕加载器（§21 Phase 3）。
  late final DanmakuLoader _danmakuLoader;

  /// 当前集已加载的弹幕（按时间排序）。
  List<DanmakuItem> _danmakuItems = const [];

  /// 弹幕显示设置（开关/透明度/字号）。
  DanmakuStyle _danmakuStyle = const DanmakuStyle();

  String? _danmakuError;
  String? _lastShownDanmakuError;

  /// 直播弹幕会话（§13.1「直播弹幕」）。仅当弹幕源是 `ws://`/`wss://` 时建立。
  LiveDanmakuSession? _liveSession;

  /// 已收到的直播弹幕（保留最近一段时间，过期条目会被修剪）。
  List<DanmakuItem> _liveItems = const [];

  /// 每条直播弹幕的接收时刻（ms）；与 `_liveItems` 一一对应，驱动生命周期。
  final Map<DanmakuItem, int> _liveReceivedAt = {};

  /// 最近一批直播弹幕到达的墙钟时刻（ms），作为渲染时钟。
  int _liveNowMs = 0;

  /// 直播弹幕连接状态与在线人数（用于 UI 展示）。
  String? _liveStatus;
  int? _liveOnline;

  /// 驱动直播弹幕逐帧重绘的定时器（仅在会话存活期间运行）。
  Timer? _liveTicker;

  /// 最近一次播放诊断快照（§23），用于播放器内展示与复制。
  PlaybackDiagnostics? _diagnostics;

  /// 当前画面显示模式，不改变原始媒体流。
  PlayerVideoFitMode _videoFitMode = PlayerVideoFitMode.contain;
  PlayerSubtitleStyle _subtitleStyle = const PlayerSubtitleStyle();
  double? _gestureRateBeforeLongPress;

  @override
  void initState() {
    super.initState();
    _request = widget.request;
    final savedFit = widget.state.playerVideoFitModeFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
    );
    if (savedFit != null) {
      for (final mode in PlayerVideoFitMode.values) {
        if (mode.name == savedFit) {
          _videoFitMode = mode;
          break;
        }
      }
    }
    _danmakuLoader = widget.danmakuLoader ?? DanmakuService();
    _controller = PlayerController()..addListener(_onControllerChanged);
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _touchControls();
      _load();
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // 连播改为**事件驱动**（`design/03` §4.1 D1）：
    // 旧实现在 `build()` 里排 postFrameCallback，任何一次通知（position/
    // duration/buffer/volume/… 每秒多次）只要 `isCompleted` 仍为 true 就会
    // 再排一个 `_onCompleted()`。于是「唤醒后点继续播放」这种纯重建动作
    // 也会立即跳下一集。
    _maybeAdvanceOnGenuineEnd();
  }

  /// 连播闸门：单次守卫 + 真播完判定（`design/03` §4.1）。
  ///
  /// 三道闸门缺一不可：
  /// 1. [_advanceInFlight] 防重入（D1）：一次连播未完成时忽略后续通知；
  /// 2. [PlayerController.isCompleted] 是 media_kit 的「到达流末尾」；
  /// 3. [isGenuineEnd] 排除提前 EOF（D2）——缓存耗尽时 `duration` 往往还没取到，
  ///    此时 `completed=true` 一定是误报。
  void _maybeAdvanceOnGenuineEnd() {
    if (_advanceInFlight) return;
    if (!_controller.isCompleted) return;
    if (!_isGenuineEnd()) return;
    _advanceInFlight = true;
    unawaited(
      _playNext().whenComplete(() {
        _advanceInFlight = false;
        // 无论连播成功还是失败，都必须复位 `completed`（`design/03` §4.1 D1）。
        //
        // 两个典型残留场景：
        // - **末集**：`_playNext()` 因 `next < 0` 直接返回，`_completed` 仍为 true，
        //   下一次重建会再跑一遍闸门（虽然结果一样，但会刷日志、且若用户此时
        //   手动切回中间某集就会误跳）；
        // - **下一集加载失败**：失败路径已自己清过（`_load()` 的失败分支），
        //   这里是幂等兼底。
        if (mounted) _controller.clearCompleted();
      }),
    );
  }

  /// 「真播完」判定（`design/03` §4.1 D2、P5）。
  ///
  /// 不信任 media_kit 的 `completed` 单独结论：它表示「到达流末尾」，
  /// **不区分**「正常播到片尾」与「提前 EOF」。判定公式与
  /// `SyncHistoryItem.completed` / 安卓 `PlaybackRecord.completed` 的 PC 侧重算
  /// 同源（`lib/core/playback.dart` 的 [isGenuineEnd]），因此三处口径不会漂移。
  bool _isGenuineEnd() => isGenuineEndDuration(
    duration: _controller.duration,
    position: _controller.position,
  );

  Future<void> _load() async {
    // 记录本次加载的「意图」，失败时用它回滚 `_request`（`design/03` §4.3 D3）。
    //
    // 为什么必须回滚：`_openTarget` 在调 `_load()` **之前**就已经把 `_request`
    // 改成了下一集（`episodeIndex` 已 +1、`clearStartPosition: true`）。
    // 若加载失败而不回滚，续播上下文（原集 + 原进度）就已丢失，
    // 用户看到的是「上一集失败 → 已经切到下一集」。
    final intent = _request;
    setState(() => _loadError = null);
    final outcome = await _controller.openWithRetry(
      _request.url,
      headers: _request.headers,
      siteKey: _request.siteKey,
      flag: _request.playbackFlag,
      episodeName: _request.episodeName,
    );
    widget.state.log.info('播放结果 ${outcome.summary}', scope: 'player');
    // 诊断：落定快照并写入日志（§23 输出引擎/格式/网络/错误）。
    final diagnostics = _controller.diagnostics;
    if (diagnostics != null) {
      widget.state.log.info(
        '播放诊断 ${diagnostics.logLine}',
        scope: 'diagnostics',
      );
      _diagnostics = diagnostics;
      widget.state.recordPlaybackDiagnostics(diagnostics);
    }
    if (!outcome.succeeded) {
      // 直播：当前线路失败时按顺序自动切到下一个线路（§13.3 播放失败可切线路）。
      if (_request.directUrl && await _fallbackLiveLine()) return;
      // 失败路径的收尾（`design/03` §4.3）：
      // 1. 回滚 `_request` 到本次加载前的意图（保住续播上下文）；
      // 2. 清除残留的 `completed`，否则重建会再次触发连播（D1）；
      // 3. 记一条含 nearEnd 判定的诊断，让「缓存耗尽」在 PC 侧可见（§4.6）。
      _logFailureDiagnostics(outcome);
      setState(() {
        _request = intent;
        _loadError = outcome.failureKind == null
            ? '播放失败'
            : describePlayerFailure(outcome.failureKind!);
      });
      _controller.clearCompleted();
      return;
    }
    // 字幕（§10.3）：装配外挂字幕候选并自动启用默认/强制字幕。
    // 字幕失败不得阻断播放，因此整段吞掉错误，只落日志与提示。
    await _configureSubtitles();
    // 弹幕（§21 Phase 3）：拉取并启用弹幕。同样不得阻断播放。
    await _configureDanmaku();
    // 进度恢复：仅对同一剧集且位置有效时执行（§10.3 播放恢复）。
    final start = _request.startPosition;
    if (start != null &&
        start > Duration.zero &&
        start < _controller.duration) {
      await _controller.seek(start);
      widget.state.log.info(
        '恢复播放进度 episode=${_request.episodeName} '
        'position=${start.inMilliseconds}ms',
        scope: 'player',
      );
    }
    _startProgressSaver();
  }

  /// 直播线路回退（§13.3）：按顺序尝试当前频道剩余的线路。
  ///
  /// 返回 true 表示已切换到另一条线路并重新加载。
  Future<bool> _fallbackLiveLine() async {
    final lines = _episodes;
    if (lines.length <= 1) return false;
    final next = _request.episodeIndex + 1;
    if (next >= lines.length) {
      widget.state.log.info(
        '直播全部线路均失败 channel=${_request.episodeName} tried=${lines.length}',
        scope: 'live',
      );
      return false;
    }
    widget.state.log.info(
      '直播线路失败，自动切换 channel=${_request.episodeName} '
      'from=${_request.episodeIndex} to=$next',
      scope: 'live',
    );
    final episode = lines[next];
    setState(() {
      _request = _request.copyWith(
        url: episode.url,
        // 直播的 `episode.url` 就是最终可播地址，入口目标与之一致。
        episodeTarget: episode.url,
        episodeName: episode.name,
        episodeIndex: next,
        clearStartPosition: true,
      );
    });
    await _load();
    return true;
  }

  /// 装配字幕（§10.3「外挂字幕」「字幕轨选择」）。
  ///
  /// 顺序：先登记播放结果里的 `subs`，再自动启用默认/强制外挂字幕。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4）。
  Future<void> _configureSubtitles() async {
    final subtitles = _request.subtitles;
    if (subtitles.isEmpty) return;
    _controller.setExternalSubtitles(
      subtitles,
      onDiscard: (sub, reason) => widget.state.log.warning(
        '字幕条目已丢弃 name=${sub.name} reason=$reason',
        scope: 'subtitle',
      ),
    );
    if (_controller.externalOptions.isEmpty) return;
    final enabled = await _controller.applyDefaultSubtitle(
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
    if (error != null) {
      widget.state.log.warning(
        '默认字幕加载失败 sub=${_controller.selectedSubtitle?.label ?? ""} $error',
        scope: 'subtitle',
      );
      _showSubtitleError(error);
      return;
    }
    if (enabled) {
      widget.state.log.info(
        '默认字幕已启用 sub=${_controller.selectedSubtitle?.label ?? ""}',
        scope: 'subtitle',
      );
    }
  }

  /// 字幕失败提示：不阻断播放，只用 SnackBar 告知（§10.4）。
  void _showSubtitleError(String message) {
    if (!mounted || _lastShownSubtitleError == message) return;
    _lastShownSubtitleError = message;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: '字幕设置', onPressed: _showSubtitleMenu),
      ),
    );
  }

  // ---------------------------------------------------------------- 弹幕

  /// 装配弹幕（§21 Phase 3「字幕/弹幕可开启和关闭」）。
  ///
  /// 自动启用第一个可用的弹幕源；直播弹幕（`ws`/`wss`）走 WebSocket 会话（§13.1）。
  /// 任何失败都只记日志/提示，绝不影响视频播放（§10.4 同语义）。
  Future<void> _configureDanmaku() async {
    final sources = _request.danmaku;
    if (sources.isEmpty) return;
    // 优先用户显式选择的源，其次第一个源（静态或直播均可）。
    var selected = sources.firstWhere(
      (source) => source.selected,
      orElse: () => sources.first,
    );
    if (selected.isLive) {
      await _connectLiveDanmaku(selected);
      return;
    }
    await _loadDanmakuSource(selected);
  }

  /// 连接直播弹幕（§13.1「直播弹幕」）。
  Future<void> _connectLiveDanmaku(DanmakuSource source) async {
    await _teardownLiveSession('replace');
    widget.state.log.info(
      '直播弹幕连接 url=${redactUrl(source.url)} name=${source.displayName}',
      scope: 'danmaku',
    );
    final session = LiveDanmakuSession(
      onEvent: _onLiveEvent,
      onMessage: _onLiveMessage,
    );
    _liveSession = session;
    _liveStatus = '连接中';
    if (mounted) setState(() {});
    try {
      await session.connect(source.url);
      // 渲染时钟：让屏幕上已有的弹幕在没有新消息时也能继续移动、到期消失。
      _startLiveTicker();
    } catch (error) {
      _liveStatus = null;
      _danmakuError = describeDanmakuFailure(error);
      widget.state.log.warning(
        '直播弹幕连接失败 source=${source.displayName} $_danmakuError',
        scope: 'danmaku',
      );
      if (mounted) {
        setState(() {});
        _showDanmakuError(_danmakuError!);
      }
    }
  }

  /// 直播弹幕会话状态回调：更新连接状态与在线人数。
  ///
  /// 连接失败（进入重连等待/停止）且从未成功时，提示一次（不反复打扰）。
  void _onLiveEvent(LiveDanmakuSessionEvent event) {
    switch (event.state) {
      case LiveDanmakuSessionState.open:
        _liveStatus = '已连接';
        break;
      case LiveDanmakuSessionState.connecting:
        _liveStatus = '连接中';
        break;
      case LiveDanmakuSessionState.retryWait:
        _liveStatus = '重连中（${(event.retryMs ?? 0) ~/ 1000}s）';
        // 首次失败提示一次；已经提示过就不重复弹。
        _danmakuError ??= '直播弹幕连接失败，正在重连';
        widget.state.log.warning(
          '直播弹幕连接失败，重连中 retry=${event.retryMs}ms '
          'detail=${event.detail ?? ""}',
          scope: 'danmaku',
        );
        if (mounted) _showDanmakuError(_danmakuError!);
        break;
      case LiveDanmakuSessionState.stopped:
        if (_liveStatus != null) _liveStatus = '已断开';
        break;
      case LiveDanmakuSessionState.idle:
      case LiveDanmakuSessionState.released:
        break;
    }
    if (event.online != null) _liveOnline = event.online;
    if (mounted) setState(() {});
  }

  /// 直播弹幕消息回调：入队实时弹幕（带接收时刻）。
  void _onLiveMessage(LiveDanmakuIncoming incoming) {
    final item = DanmakuItem(
      timeMs: incoming.receivedAtMs,
      text: incoming.text,
      type: DanmakuType.scroll,
      color: incoming.color,
      textSizeSp: incoming.textSizeSp,
    );
    _liveReceivedAt[item] = incoming.receivedAtMs;
    _liveNowMs = incoming.receivedAtMs;
    _liveItems = [..._liveItems, item];
    _pruneLiveItems();
    if (mounted) setState(() {});
  }

  /// 修剪直播弹幕：超过 [scrollDurationMs] + 余量的条目不再显示（回收内存）。
  void _pruneLiveItems() {
    final cutoff = _liveNowMs - 15000;
    _liveItems = _liveItems.where((item) {
      final receivedAt = _liveReceivedAt[item];
      return receivedAt != null && receivedAt >= cutoff;
    }).toList();
    _liveReceivedAt.removeWhere((item, receivedAt) => receivedAt < cutoff);
  }

  /// 直播弹幕渲染时钟：定时推进 [liveNowMs]，使已过期的弹幕逐帧淡出。
  /// 会话断开时停止（没有新消息就不需要重绘）。
  void _startLiveTicker() {
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      // 渲染时钟用真实墙钟：即使没有新消息，也要让屏幕上已有的弹幕继续移动。
      _liveNowMs = DateTime.now().millisecondsSinceEpoch;
      if (mounted) setState(() {});
    });
  }

  /// 关闭直播弹幕会话（请求销毁/切集时调用）。
  Future<void> _teardownLiveSession(String reason) async {
    final session = _liveSession;
    _liveSession = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    _liveItems = const [];
    _liveReceivedAt.clear();
    _liveOnline = null;
    _liveStatus = null;
    if (session != null) {
      try {
        await session.dispose();
      } catch (_) {
        // 销毁失败不抛出；会话是尽力而为的附加资源。
      }
    }
  }

  /// 拉取并启用一个弹幕源；失败只提示，不影响播放。
  Future<void> _loadDanmakuSource(DanmakuSource source) async {
    final stopwatch = Stopwatch()..start();
    try {
      final document = await _danmakuLoader.load(
        source,
        headers: _request.subtitleHeaders,
      );
      _danmakuItems = document.items;
      _danmakuError = null;
      widget.state.log.info(
        '弹幕已加载 ${document.logLine} elapsed=${stopwatch.elapsed.inMilliseconds}ms',
        scope: 'danmaku',
      );
      if (mounted) setState(() {});
    } catch (error) {
      _danmakuItems = const [];
      _danmakuError = describeDanmakuFailure(error);
      widget.state.log.warning(
        '弹幕加载失败 source=${source.displayName} $_danmakuError',
        scope: 'danmaku',
      );
      if (!mounted) return;
      setState(() {});
      _showDanmakuError(_danmakuError!);
    }
  }

  /// 弹幕失败提示：不阻断播放（§10.4 同语义）。
  void _showDanmakuError(String message) {
    if (_lastShownDanmakuError == message) return;
    _lastShownDanmakuError = message;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// 弹幕总开关（§13.3「弹幕可开启和关闭」）。
  void _toggleDanmaku() {
    _danmakuStyle = _danmakuStyle.copyWith(enabled: !_danmakuStyle.enabled);
    widget.state.log.info(
      '弹幕 ${_danmakuStyle.enabled ? "开启" : "关闭"} '
      'items=${_danmakuItems.length}',
      scope: 'danmaku',
    );
    if (mounted) setState(() {});
  }

  /// 弹幕设置菜单（§17.5）：透明度 / 字号 / 滚动 / 顶部 / 底部。
  Future<void> _showDanmakuSettings() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('弹幕设置'),
              titleTextStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            _settingTile(
              '弹幕开关',
              subtitle: _danmakuStyle.enabled ? '已开启' : '已关闭',
              onTap: () async {
                Navigator.of(context).pop('toggle');
              },
            ),
            _settingTile(
              '透明度 ${(_danmakuStyle.opacity * 100).round()}%',
              onTap: () async {
                Navigator.of(context).pop('opacity');
              },
            ),
            _settingTile(
              '字号 ${(_danmakuStyle.textScale * 100).round()}%',
              onTap: () async {
                Navigator.of(context).pop('scale');
              },
            ),
            _settingTile(
              '滚动弹幕',
              subtitle: _danmakuStyle.showScroll ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('scroll');
              },
            ),
            _settingTile(
              '顶部弹幕',
              subtitle: _danmakuStyle.showTop ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('top');
              },
            ),
            _settingTile(
              '底部弹幕',
              subtitle: _danmakuStyle.showBottom ? '显示' : '隐藏',
              onTap: () async {
                Navigator.of(context).pop('bottom');
              },
            ),
            _settingTile(
              '重新加载弹幕',
              onTap: () async {
                Navigator.of(context).pop('reload');
              },
            ),
            ListTile(
              onTap: () => Navigator.of(context).pop('close'),
              title: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case 'toggle':
        _toggleDanmaku();
      case 'opacity':
        _danmakuStyle = _danmakuStyle.copyWith(
          opacity: _nextStep(_danmakuStyle.opacity, 0.1, 0.3, 1.0),
        );
        if (mounted) setState(() {});
      case 'scale':
        _danmakuStyle = _danmakuStyle.copyWith(
          textScale: _nextStep(_danmakuStyle.textScale, 0.25, 0.5, 2.0),
        );
        if (mounted) setState(() {});
      case 'scroll':
        _danmakuStyle = _danmakuStyle.copyWith(
          showScroll: !_danmakuStyle.showScroll,
        );
        if (mounted) setState(() {});
      case 'top':
        _danmakuStyle = _danmakuStyle.copyWith(showTop: !_danmakuStyle.showTop);
        if (mounted) setState(() {});
      case 'bottom':
        _danmakuStyle = _danmakuStyle.copyWith(
          showBottom: !_danmakuStyle.showBottom,
        );
        if (mounted) setState(() {});
      case 'reload':
        // 重新拉取时绕过缓存，否则“重新加载”会命中旧结果。
        DanmakuSource? source;
        for (final candidate in _request.danmaku) {
          if (!candidate.isLive) {
            source = candidate;
            break;
          }
        }
        source ??= _request.danmaku.isEmpty ? null : _request.danmaku.first;
        if (source != null) await _loadDanmakuSource(source);
    }
  }

  /// 步进到下一个可选值（循环）。
  double _nextStep(double current, double step, double min, double max) {
    final next = current + step;
    return next > max ? min : next;
  }

  Widget _settingTile(
    String title, {
    String? subtitle,
    required VoidCallback onTap,
  }) => ListTile(
    leading: const Icon(Icons.tune),
    title: Text(title),
    trailing: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 13)),
    onTap: onTap,
  );

  /// 字幕菜单：外挂 / 内嵌 / 关闭（§13.3「字幕可开启和关闭」）。
  Future<void> _showSubtitleMenu() async {
    final options = _controller.subtitleOptions;
    if (options.length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前视频没有可用字幕轨')));
      return;
    }
    final selected = await showModalBottomSheet<SubtitleOption>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                leading: Icon(
                  option.id == SubtitleOption.offId
                      ? Icons.subtitles_off_outlined
                      : (option.isExternal
                            ? Icons.description_outlined
                            : Icons.subtitles_outlined),
                ),
                title: Text(option.label),
                subtitle: option.isExternal
                    ? Text(
                        '外挂 · ${option.format.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : const Text('内嵌'),
                trailing: _controller.selectedSubtitle == option
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    _controller.clearSubtitleError();
    final ok = await _controller.selectSubtitle(
      selected,
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
    if (ok) {
      widget.state.log.info(
        '字幕已切换 sub=${selected.label} kind=${selected.kind.name}',
        scope: 'subtitle',
      );
      return;
    }
    widget.state.log.warning(
      '字幕切换失败 sub=${selected.label} ${error ?? "未知错误"}',
      scope: 'subtitle',
    );
    if (error != null) _showSubtitleError(error);
  }

  /// 播放中周期性写入进度（§15.2 “播放中写入进度”）。
  void _startProgressSaver() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _persistProgress();
    });
  }

  void _persistProgress() {
    if (_controller.duration <= Duration.zero) return;
    final position = _controller.position;
    final duration = _controller.duration;
    widget.state.recordProgress(
      vod: Vod(
        vodId: _request.vodId,
        vodName: _request.vodName,
        vodPic: _request.vodPic,
      ),
      flag: _request.playbackFlag,
      episodeName: _request.episodeName,
      // 存**站点入口目标**而不是解析后的播放地址：历史续播要把这个值回传给站点
      // 重新解析（§15.2）。存播放地址会得到「站点返回业务错误」，因为那是带时效
      // 签名的 CDN/代理地址，站点认不了（用户反馈 2026-10-09）。
      episodeId: _request.episodeTarget,
      position: position,
      duration: duration,
      siteKey: _request.siteKey,
    );
    // 季度进度（`02` §6.2）：`UnknownSeason` 不写，电影不写。
    // 来源 `history` 无论如何都写（既有行为不变）。
    final identity = _request.tmdb;
    if (identity != null && identity.hasIdentity) {
      widget.state.recordSeasonProgress(
        identity: identity,
        scope: identity.hasSeason
            ? KnownSeason(identity.seasonNumber)
            : const UnknownSeason(),
        siteKey: _request.siteKey,
        vodId: _request.vodId,
        sourceFlag: _request.playbackFlag,
        sourceEpisodeName: _request.episodeName,
        // 同样必须存**站点入口目标**：`TmdbEpisodeLocator` 拿它与 `VodEpisode.url`
        // （详情里的入口目标）精确比对来定位集号，存解析后的可播地址（T4 站点是
        // 本地代理 `127.0.0.1/p/<token>/…`）永远匹配不上，季度续播就定位不到集。
        // 同时也让 `sourceHistoryKey` 与 `history.episodeId` 指向同一个值。
        sourceEpisodeUrl: _request.episodeTarget,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      );
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _saveTimer?.cancel();
    _controlHideTimer?.cancel();
    _endGestureSpeed();
    _persistProgress();
    // 直播弹幕会话是网络资源，必须显式关闭（§20 资源释放）。
    unawaited(_teardownLiveSession('dispose'));
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = true;
      _controlsVisible = true;
    });
    _touchControls();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted) return;
    setState(() {
      _fullscreen = false;
      _controlsVisible = true;
    });
    _controlHideTimer?.cancel();
  }

  Future<void> _toggleFullscreen() async {
    final next = !await windowManager.isFullScreen();
    try {
      if (next) {
        // Windows 全屏失败时如果只更新 Flutter 状态，标题栏会残留；
        // 先切无边框，再切系统全屏，最后用实际窗口状态回读确认。
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setAsFrameless();
        await windowManager.setFullScreen(true);
        await windowManager.focus();
        var actual = await windowManager.isFullScreen();
        if (!actual) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await windowManager.setFullScreen(true);
          actual = await windowManager.isFullScreen();
        }
        if (!actual) {
          await windowManager.setTitleBarStyle(
            TitleBarStyle.normal,
            windowButtonVisibility: true,
          );
          throw StateError('Windows 全屏状态未确认');
        }
      } else {
        await windowManager.setFullScreen(false);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
          windowButtonVisibility: true,
        );
      }
    } catch (error) {
      widget.state.log.warning('切换全屏失败：$error', scope: 'player');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('全屏切换失败，请再试一次')));
      }
      return;
    }
    if (!mounted) return;
    final actual = await windowManager.isFullScreen();
    setState(() {
      _fullscreen = actual;
      _controlsVisible = true;
    });
    _touchControls();
  }

  Future<void> _exitFullscreen() async {
    if (await windowManager.isFullScreen()) await _toggleFullscreen();
  }

  List<VodEpisode> get _episodes {
    for (final line in _request.playLines) {
      if (line.flag == _request.flag) return line.episodes;
    }
    return const [];
  }

  String _playbackFlagFor(String displayFlag) {
    for (final line in _request.playLines) {
      if (line.flag == displayFlag) return line.playbackFlag;
    }
    return displayFlag == _request.flag ? _request.playbackFlag : displayFlag;
  }

  Future<void> _playEpisode(int index, {String? overrideFlag}) async {
    final flag = overrideFlag ?? _request.flag;
    List<VodPlayLine> lines = _request.playLines;
    if (overrideFlag != null) {
      // 线路切换后需要按新线路解析地址。
      final target = lines
          .firstWhere(
            (line) => line.flag == overrideFlag,
            orElse: () => VodPlayLine(flag: overrideFlag, episodes: const []),
          )
          .episodes;
      if (index < 0 || index >= target.length) return;
      _episodesCache = target;
      await _openTarget(target[index], flag: overrideFlag, episodeIndex: index);
      return;
    }
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (index < 0 || index >= episodes.length) return;
    await _openTarget(episodes[index], flag: flag, episodeIndex: index);
  }

  List<VodEpisode> _episodesCache = const [];

  /// 失败时的可观测性（`design/03` §4.6）。
  ///
  /// 缓存耗尽（提前 EOF）当前在 PC 侧**不可见**：media_kit 很可能无法区分
  /// 「正常播到片尾」与「源站断流」，因此退化为记录失败瞬间的
  /// `position`/`duration`/`buffered` 与 `nearEnd` 结论。
  ///
  /// 关键作用：`nearEnd=false` 的失败**永远**不触发连播（已由
  /// [_maybeAdvanceOnGenuineEnd] 的真播完闸门保证），这条日志是事后
  /// 排查「到底是不是提前 EOF」的唯一线索。
  void _logFailureDiagnostics(PlayerLoadOutcome outcome) {
    final duration = _controller.duration;
    final position = _controller.position;
    final nearEnd = isGenuineEndDuration(
      duration: duration,
      position: position,
    );
    widget.state.log.warning(
      '播放失败定位 kind=${outcome.failureKind?.name ?? "unknown"} '
      'position=${position.inMilliseconds}ms '
      'duration=${duration.inMilliseconds}ms '
      'buffered=${_controller.buffered.inMilliseconds}ms '
      'nearEnd=$nearEnd '
      'episode=${_request.episodeName} '
      'episodeIndex=${_request.episodeIndex}',
      scope: 'player',
    );
  }

  Future<void> _openTarget(
    VodEpisode episode, {
    required String flag,
    required int episodeIndex,
  }) async {
    final state = widget.state;
    try {
      // 直播：地址已是最终可播地址，不经站点解析（§13.3）。
      final String url;
      final List<SubtitleInfo> subtitles;
      final List<DanmakuSource> danmaku;
      if (_request.directUrl) {
        url = episode.url;
        subtitles = _request.subtitles;
        danmaku = _request.danmaku;
      } else {
        final decision = await state.resolvePlayback(
          episodeTarget: episode.url,
          flag: _playbackFlagFor(flag),
          vodId: _request.vodId,
        );
        if (decision == null || decision.url == null) {
          throw AppError(
            AppErrorKind.playbackUrlMissing,
            '播放决策没有返回可用地址',
            detail: 'flag=$flag episode=${episode.name}',
          );
        }
        url = decision.url!;
        // 换集后字幕/弹幕也要换成该集结果里的 subs/danmaku（§10.3、Phase 3）。
        subtitles = decision.subs;
        danmaku = decision.danmaku;
      }
      setState(() {
        _loadError = null;
        _request = _request.copyWith(
          url: url,
          // 换集必须把「站点入口目标」一起换成该集的输入值（`episode.url`），
          // 否则历史里记的仍是上一集的入口，续播会跳回上一集。
          episodeTarget: episode.url,
          episodeName: episode.name,
          flag: flag,
          playbackFlag: _playbackFlagFor(flag),
          headers: _request.directUrl ? _request.headers : null,
          episodeIndex: episodeIndex,
          clearStartPosition: true,
          subtitles: subtitles,
          danmaku: danmaku,
        );
        _episodesCache = const [];
        // 换集后旧弹幕立即失效，避免新集开头出现上一集的弹幕；
        // 直播弹幕连接也必须断开，否则切集后旧会话会继续推流到新画面上。
        _danmakuItems = const [];
        _danmakuError = null;
      });
      await _teardownLiveSession('episode-change');
      _persistProgress();
      await _load();
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      setState(() => _loadError = failure.userMessage);
      state.log.error('切换剧集失败 ${failure.logLine}', scope: 'player');
    }
  }

  /// 从**最新进度**续播（失败态三出口之二，`design/03` §4.4/§4.5）。
  ///
  /// **为什么必须重新查库**：失败期间进度仍在周期写入（[_persistProgress]），
  /// 最新值可能比 `_request.startPosition` 更靠后。用旧值续播会让用户
  /// 回到比失败点更早的位置。
  ///
  /// 恢复路径**不得**触发连播（`design/03` §4.5 步骤 5、P5）：
  /// 这里只重建 `_request` 并重新 `_load()`；`_load()` 成功路径不调
  /// `_playNext()`，且 `open()` 会先把 `_completed` 复位。
  Future<void> _resumeFromLatestProgress() async {
    final state = widget.state;
    final latest = state.resumePositionFor(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      flag: _request.flag,
      episodeId: _request.episodeTarget,
      // 同步来的历史 `episode_id` 是安卓哈希，与 `episodeTarget` 不同源，
      // 需要集名兜底（详见 `AppDatabase.findHistory` 的三级匹配）。
      episodeName: _request.episodeName,
    );
    // 查不到（已看完 / 无记录 / 低于续播下限）时退回「重试本集」语义，
    // 而不是静默无动作——用户点了按钮就必须有反馈。
    if (latest == null) {
      widget.state.log.info(
        '失败态续播：库内无可续播进度，退化为重试本集 '
        'episode=${_request.episodeName}',
        scope: 'player',
      );
      await _load();
      return;
    }
    widget.state.log.info(
      '失败态续播：position=${latest.inMilliseconds}ms '
      'episode=${_request.episodeName}',
      scope: 'player',
    );
    setState(() {
      _request = _request.copyWith(startPosition: latest);
    });
    await _load();
  }

  Future<void> _playNext() async {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final identity = _request.tmdb;
    // 自动连播**不跨季度**（`04` §8.4）：季度边界处停止。
    final next = identity == null || !identity.hasSeason
        ? (_request.episodeIndex + 1 < episodes.length
              ? _request.episodeIndex + 1
              : -1)
        : TmdbAutoPlay.nextIndex(
            episodes: episodes,
            currentIndex: _request.episodeIndex,
            availableSeasons: [identity.seasonNumber],
            selectedSeason: identity.seasonNumber,
          );
    if (next < 0) return;
    await _openTarget(episodes[next], flag: _request.flag, episodeIndex: next);
  }

  Future<void> _playPrevious() async {
    final episodes = _episodesCache.isNotEmpty ? _episodesCache : _episodes;
    if (episodes.isEmpty) return;
    final previous = _request.episodeIndex - 1;
    if (previous < 0) return;
    await _openTarget(
      episodes[previous],
      flag: _request.flag,
      episodeIndex: previous,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = buildPlayerShortcuts(
      togglePlay: _controller.playOrPause,
      seekBackward: () => _controller.seekBy(const Duration(seconds: -10)),
      seekForward: () => _controller.seekBy(const Duration(seconds: 10)),
      volumeUp: () => _controller.setVolume(_controller.volume + 5),
      volumeDown: () => _controller.setVolume(_controller.volume - 5),
      toggleMute: _controller.toggleMute,
      previousEpisode: _playPrevious,
      nextEpisode: _playNext,
      toggleFullscreen: _toggleFullscreen,
      exitFullscreen: _exitFullscreen,
    );

    if (_controller.isCompleted) {
      // 连播**不**在这里触发（`design/03` §4.1 D1）：
      // `build()` 会被任何一次 `setState` 走到，在这里排 postFrameCallback
      // 等于把「重建」当成「播完」的信号。真正的触发点是
      // `_onControllerChanged()` 里的 `_maybeAdvanceOnGenuineEnd()`。
      //
      // 这里只保留一个**兜底**：若因异常路径漏掉了事件（例如控制器在
      // `initState` 订阅生效前就已 completed），下一次重建时补一次判定。
      // 判定本身带单次守卫与真播完闸门，因此重复调用是安全的。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeAdvanceOnGenuineEnd();
      });
    }

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: _fullscreen
              ? null
              : AppBar(
                  title: Text(
                    '${_request.vodName} · ${_request.episodeName}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    // 播放中真正会**反复碰**的三个留在外面：
                    // 字幕轨、弹幕开关、全屏。
                    IconButton(
                      tooltip: '字幕轨',
                      icon: const Icon(Icons.subtitles_outlined),
                      onPressed: _showSubtitleMenu,
                    ),
                    IconButton(
                      tooltip: _danmakuStyle.enabled ? '弹幕（开启）' : '弹幕（关闭）',
                      icon: Icon(
                        _danmakuStyle.enabled
                            ? Icons.comment
                            : Icons.comment_bank_outlined,
                      ),
                      onPressed: _toggleDanmaku,
                    ),
                    // 全屏**不在这里**：它归底部控制条（一个动作只有一个家）。
                    // 顶栏常驻、底部栏会随不活动隐藏，所以把「轨道类」留在顶栏、
                    // 「播放/显示类」放底部栏——两边不再重复同一个动作。
                    // 其余五个是**设一次**或**出问题时才用**的，收进溢出菜单。
                    //
                    // 原来这 8 个图标同尺寸、同字重、平铺成一行，扫视时找不到落点
                    // （用户反馈 2026-10-11：「图标也处理吧」）。分组依据是**使用
                    // 时机**，不是功能相似度：播放中要碰的留在外面，配置与诊断收进去。
                    //
                    // 注意：字幕轨与弹幕的 tooltip 被集成测试按**精确串**查找并直接
                    // `tap`（`subtitle_flow_test.dart`、`danmaku_flow_test.dart`），
                    // 所以它们**不能**被收进菜单——收进去测试就点不到了。
                    PopupMenuButton<_PlayerMenuAction>(
                      tooltip: '更多',
                      icon: const Icon(Icons.more_vert),
                      onSelected: (action) {
                        switch (action) {
                          case _PlayerMenuAction.subtitleStyle:
                            _showSubtitleStyleSettings();
                          case _PlayerMenuAction.danmakuSettings:
                            _showDanmakuSettings();
                          case _PlayerMenuAction.videoFit:
                            _showVideoFitSettings();
                          case _PlayerMenuAction.mediaInfo:
                            _showMediaInfo();
                          case _PlayerMenuAction.diagnostics:
                            _showDiagnostics();
                          case _PlayerMenuAction.shortcuts:
                            _showShortcutHelp();
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(
                          _PlayerMenuAction.subtitleStyle,
                          Icons.format_color_text_outlined,
                          '字幕样式',
                        ),
                        _menuItem(
                          _PlayerMenuAction.danmakuSettings,
                          Icons.comment_outlined,
                          '弹幕设置',
                        ),
                        _menuItem(
                          _PlayerMenuAction.videoFit,
                          Icons.aspect_ratio_outlined,
                          '画面比例与缩放',
                        ),
                        _menuItem(
                          _PlayerMenuAction.mediaInfo,
                          Icons.info_outline,
                          '媒体信息',
                        ),
                        // 诊断只有在真的拿到了诊断数据时才有意义；
                        // 没有数据时**灰掉而不是隐藏**——隐藏会让用户以为功能没了。
                        PopupMenuItem<_PlayerMenuAction>(
                          value: _PlayerMenuAction.diagnostics,
                          enabled: _diagnostics != null,
                          child: _menuRow(
                            Icons.monitor_heart_outlined,
                            '播放诊断',
                            enabled: _diagnostics != null,
                          ),
                        ),
                        _menuItem(
                          _PlayerMenuAction.shortcuts,
                          Icons.keyboard,
                          '快捷键说明',
                        ),
                      ],
                    ),
                  ],
                ),
          body: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControlsByGesture,
                  onDoubleTap: _handleDoubleTapGesture,
                  onLongPressStart: (_) => _beginGestureSpeed(),
                  onLongPressEnd: (_) => _endGestureSpeed(),
                  onLongPressCancel: _endGestureSpeed,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Video(
                          controller: _controller.videoController,
                          fit: _videoFitMode.fit,
                          aspectRatio: _videoFitMode.aspectRatio,
                          controls: NoVideoControls,
                          subtitleViewConfiguration:
                              _subtitleStyle.configuration,
                        ),
                      ),
                      // 弹幕叠加层（§21 Phase 3 / §13.1 直播弹幕）：绘制在视频上方、
                      // 控制层下方。关闭时（style.enabled=false）不绘制任何内容。
                      Positioned.fill(
                        child: DanmakuOverlay(
                          items: _danmakuItems,
                          position: _controller.position,
                          style: _danmakuStyle,
                          liveItems: _liveItems,
                          liveNowMs: _liveNowMs,
                        ),
                      ),
                      if (_controller.isLoading)
                        const Positioned.fill(
                          child: LoadingBlock(),
                        ),
                      if (_loadError != null)
                        Positioned.fill(
                          child: Center(
                            child: _PlayerErrorOverlay(
                              message: _loadError!,
                              url: _request.url,
                              onRetry: _load,
                              onResume: _resumeFromLatestProgress,
                              onNext: _playNext,
                              canGoNext:
                                  (_episodesCache.isNotEmpty
                                      ? _episodesCache.length
                                      : _episodes.length) >
                                  _request.episodeIndex + 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_controlsVisible)
                Listener(
                  onPointerDown: (_) => _touchControls(),
                  child: _ControlBar(
                    controller: _controller,
                    request: _request,
                    onToggleFullscreen: _toggleFullscreen,
                    onPrevious: _playPrevious,
                    onNext: _playNext,
                    onSelectEpisode: (index) => _playEpisode(index),
                    onSelectLine: (flag) => _playEpisode(0, overrideFlag: flag),
                    liveStatus: _liveStatus,
                    liveOnline: _liveOnline,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int number) => number.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  String _formatBitrate(num? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '未知';
    final bits = bitsPerSecond.toDouble();
    if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
    if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} Kbps';
    return '${bits.toStringAsFixed(0)} bps';
  }

  String _mediaResolution() {
    final width = _controller.videoWidth;
    final height = _controller.videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return '未知';
    }
    return '$width×$height';
  }

  void _touchControls() {
    _controlHideTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _controlHideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControlsByGesture() {
    if (resolvePlayerGesture(doubleTap: false, fullscreen: _fullscreen) ==
        PlayerGestureAction.toggleControls) {
      if (_controlsVisible) {
        _controlHideTimer?.cancel();
        setState(() => _controlsVisible = false);
      } else {
        _touchControls();
      }
    }
  }

  Future<void> _handleDoubleTapGesture() async {
    switch (resolvePlayerGesture(doubleTap: true, fullscreen: _fullscreen)) {
      case PlayerGestureAction.enterFullscreen:
        await _toggleFullscreen();
      case PlayerGestureAction.togglePlayback:
        await _controller.playOrPause();
        _touchControls();
      case PlayerGestureAction.toggleControls:
        _toggleControlsByGesture();
    }
  }

  void _beginGestureSpeed() {
    if (_gestureRateBeforeLongPress != null) return;
    _gestureRateBeforeLongPress = _controller.rate;
    _controller.setRate(2.0);
    _touchControls();
  }

  void _endGestureSpeed() {
    final previous = _gestureRateBeforeLongPress;
    _gestureRateBeforeLongPress = null;
    if (previous != null) _controller.setRate(previous);
  }

  Future<void> _showSubtitleStyleSettings() async {
    var draft = _subtitleStyle;
    final result = await showModalBottomSheet<PlayerSubtitleStyle>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('字幕样式', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '去除黑色字幕底框，并调整字幕位置、描边和时间偏移。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 18),
                Text('文字颜色', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final color in const [
                      Colors.white,
                      Colors.yellow,
                      Colors.cyanAccent,
                      Colors.lightGreenAccent,
                      Colors.orangeAccent,
                      Colors.pinkAccent,
                    ])
                      InkWell(
                        onTap: () => setModalState(
                          () => draft = draft.copyWith(color: color),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                              color: draft.color == color
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white54,
                              width: draft.color == color ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '字幕底色（默认透明）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: draft.backgroundOpacity,
                  min: 0,
                  max: 0.8,
                  divisions: 8,
                  label: '${(draft.backgroundOpacity * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(backgroundOpacity: value),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '描边宽度 ${draft.outlineWidth.toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.outlineWidth,
                  min: 0,
                  max: 4,
                  divisions: 8,
                  label: draft.outlineWidth.toStringAsFixed(1),
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(outlineWidth: value),
                  ),
                ),
                Text(
                  '字号 ${((draft.textScale) * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.textScale,
                  min: 0.6,
                  max: 1.8,
                  divisions: 12,
                  label: '${(draft.textScale * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(textScale: value),
                  ),
                ),
                Text(
                  '字幕位置 ${draft.bottomPadding.round()}dp',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.bottomPadding,
                  min: 0,
                  max: 120,
                  divisions: 12,
                  label: '${draft.bottomPadding.round()}dp',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(bottomPadding: value),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setModalState(() {
                        draft = const PlayerSubtitleStyle();
                      }),
                      child: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(draft),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _subtitleStyle = result);
  }

  Future<void> _showVideoFitSettings() async {
    final selected = await showModalBottomSheet<PlayerVideoFitMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              leading: Icon(Icons.aspect_ratio_outlined),
              title: Text('画面比例与缩放'),
              subtitle: Text('只改变显示方式，不改变原始视频'),
            ),
            for (final mode in PlayerVideoFitMode.values)
              ListTile(
                selected: mode == _videoFitMode,
                leading: Icon(
                  mode == _videoFitMode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(mode.label),
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _videoFitMode = selected);
    widget.state.rememberPlayerVideoFitMode(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      mode: selected.name,
    );
  }

  void _showMediaInfo() {
    final video = _controller.selectedVideoTrack;
    final audio = _controller.selectedAudioTrack;
    final params = _controller.videoParams;
    final audioParams = _controller.audioParams;
    final diagnostics = _diagnostics;
    final rows = <(String, String)>[
      ('分辨率', _mediaResolution()),
      (
        '显示比例',
        params.aspect == null ? '未知' : params.aspect!.toStringAsFixed(3),
      ),
      ('视频编码', video?.codec?.isNotEmpty == true ? video!.codec! : '未知'),
      (
        '帧率',
        video?.fps == null ? '未知' : '${video!.fps!.toStringAsFixed(2)} fps',
      ),
      ('视频码率', _formatBitrate(video?.bitrate)),
      ('像素格式', params.pixelformat ?? '未知'),
      ('音频编码', audio?.codec?.isNotEmpty == true ? audio!.codec! : '未知'),
      (
        '采样率',
        audioParams.sampleRate == null ? '未知' : '${audioParams.sampleRate} Hz',
      ),
      ('声道', audioParams.hrChannels ?? audioParams.channels ?? '未知'),
      ('音频码率', _formatBitrate(_controller.audioBitrate ?? audio?.bitrate)),
      ('格式', diagnostics?.format.label ?? '未知'),
      ('缓冲', _formatDuration(_controller.buffered)),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('媒体信息'),
        content: SizedBox(
          width: 480,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final (label, value) = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(child: SelectableText(value)),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 展示播放诊断（§23）：引擎/格式/网络/错误与阶段耗时，可一键复制。
  void _showDiagnostics() {
    final diagnostics = _diagnostics;
    if (diagnostics == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('播放诊断'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: SelectableText(
              diagnostics.report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: diagnostics.report));
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('快捷键'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (key, description) in playerShortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('$key：$description'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 播放器顶栏**溢出菜单**的动作。
///
/// 这些是「设一次」或「出问题时才用」的能力，与播放中反复碰的字幕/弹幕/全屏
/// 分开——分组依据是**使用时机**。
enum _PlayerMenuAction {
  subtitleStyle,
  danmakuSettings,
  videoFit,
  mediaInfo,
  diagnostics,
  shortcuts,
}

/// 溢出菜单里的一行（图标 + 文字）。
Widget _menuRow(IconData icon, String label, {bool enabled = true}) {
  return Row(
    children: [
      Icon(icon, size: 18),
      const SizedBox(width: AppSpace.md),
      Text(label),
    ],
  );
}

PopupMenuItem<_PlayerMenuAction> _menuItem(
  _PlayerMenuAction value,
  IconData icon,
  String label,
) {
  return PopupMenuItem<_PlayerMenuAction>(
    value: value,
    child: _menuRow(icon, label),
  );
}

/// 底部控制条的分组线。
///
/// 控制条是一整排同尺寸图标，没有分组时扫视找不到落点。一条发丝竖线比
/// 加间距更有效——间距只说明"隔开了"，线说明"这是另一组"。
Widget _controlBarDivider(BuildContext context) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
    child: Container(
      width: 1,
      height: 20,
      color: Theme.of(context).dividerColor,
    ),
  );
}

class _PlayerErrorOverlay extends StatelessWidget {
  const _PlayerErrorOverlay({
    required this.message,
    required this.url,
    required this.onRetry,
    required this.onResume,
    required this.onNext,
    required this.canGoNext,
  });

  final String message;
  final String url;

  /// 出口一：用**原** `_request`（原集、原 `startPosition`）重新加载。
  final VoidCallback onRetry;

  /// 出口二：重新查库拿最新进度后续播（`design/03` §4.4）。
  final VoidCallback onResume;

  /// 出口三：显式用户动作地切下一集（**不是**自动连播）。
  final VoidCallback onNext;
  final bool canGoNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.all(AppSpace.xl),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        // 这是盖在**视频画面**上的浮层，必须始终够暗才读得清——
        // 但用设计系统的夜空底（带色相）而不是裸 `Colors.black`：
        // 纯黑会从整个世界（深靛夜空）里掉出来。
        color: AppPalette.nightGround.withValues(alpha: 0.92),
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: semantic.statusFailed),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: semantic.statusFailed),
              const SizedBox(width: AppSpace.sm),
              Text(
                '播放失败',
                // 用真实存在的 w700，不用 w600：雅黑没有真 Medium，
                // w600 会走合成加粗（笔画粘连、小字号发糊）。
                // 这是全站统一修过的同一类缺陷，浮层这里漏了。
                style: theme.textTheme.titleMedium?.copyWith(
                  color: AppPalette.nightInk,
                  fontWeight: AppWeight.title,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.nightInk,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          SelectableText(
            '地址：${redactUrl(url)}',
            style: theme.textTheme.bodySmall?.copyWith(
              // 从底色色相染出的副文本，不是 `Colors.white70`。
              color: AppPalette.nightInkMuted,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          // 失败态必须提供三个明确出口（`design/03` §4.4）：
          // 只给一行错误会让用户只能反复点「重试」，而真正的诉求往往是
          // 「从刚才的位置接着看」。
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('player-error-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试本集'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('player-error-resume'),
                onPressed: onResume,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('从最近进度续播'),
              ),
              if (canGoNext)
                OutlinedButton.icon(
                  key: const ValueKey('player-error-next'),
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next, size: 18),
                  label: const Text('播放下一集'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.controller,
    required this.request,
    required this.onToggleFullscreen,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectEpisode,
    required this.onSelectLine,
    this.liveStatus,
    this.liveOnline,
  });

  final PlayerController controller;
  final PlaybackRequest request;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<int> onSelectEpisode;
  final ValueChanged<String> onSelectLine;

  /// 直播弹幕连接状态（仅直播弹幕时非空）。
  final String? liveStatus;

  /// 直播弹幕在线人数（收到 `online` 帧后非空）。
  final int? liveOnline;

  String _formatDuration(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int number) => number.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  String _formatBitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '';
    if (bitsPerSecond >= 1000000) {
      return '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
    }
    return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
  }

  String _mediaSummary(PlayerController controller) {
    final width = controller.videoWidth;
    final height = controller.videoHeight;
    final track = controller.selectedVideoTrack;
    return [
      if (width != null && height != null) '$width×$height',
      if (track?.codec?.isNotEmpty == true) track!.codec!,
      if (track?.fps != null && track!.fps! > 0)
        '${track.fps!.toStringAsFixed(2)} fps',
      if (_formatBitrate(track?.bitrate).isNotEmpty)
        _formatBitrate(track?.bitrate),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final duration = controller.duration;
    final maxMs = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final value = controller.position.inMilliseconds
        .clamp(0, maxMs.toInt())
        .toDouble();
    final episodes = () {
      for (final line in request.playLines) {
        if (line.flag == request.flag) return line.episodes;
      }
      return const <VodEpisode>[];
    }();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      // 控制条用**主题底色的半透明纱**，不是不透明面：
      // 播放器是全幅视频表面，控制条压住画面底部会显得很重；
      // 半透明让画面透出来，同时文字仍然落在可控的底色上（对比度成立）。
      //
      // 为什么不做成"永远深色"：播放器背景是视频、不是应用底色，所以
      // 深色纱对亮画面对比度最好——但那样在亮色主题下，主题给的深色图标
      // 会压在深色纱上（实测约 3.5:1，不足）。要做对需要在播放器页整体
      // 套一层暗色 Theme 作用域，那是一次独立改动，不夹在这里半做。
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // 时间必须用**等宽字形**：比例字形下秒数每跳一次，整行时间
              // 就会左右抖动，读进度时很难受。
              Text(
                _formatDuration(controller.position),
                style: tabular(Theme.of(context).textTheme.bodyMedium!),
              ),
              Expanded(
                child: Slider(
                  value: value,
                  max: maxMs,
                  onChanged: duration.inMilliseconds <= 0
                      ? null
                      : (next) => controller.seek(
                          Duration(milliseconds: next.round()),
                        ),
                ),
              ),
              Text(
                _formatDuration(duration),
                style: tabular(Theme.of(context).textTheme.bodyMedium!),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '上一集（[）',
                onPressed: onPrevious,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: controller.isPlaying ? '暂停（空格）' : '播放（空格）',
                onPressed: controller.playOrPause,
                icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
              ),
              IconButton(
                tooltip: '下一集（]）',
                onPressed: onNext,
                icon: const Icon(Icons.skip_next),
              ),
              // 分组：传输 → 音量 → 速率/线路 → 显示 → 状态。
              // 十几个同尺寸图标平铺时，分组线是唯一能让眼睛停下来的东西。
              _controlBarDivider(context),
              IconButton(
                tooltip: controller.muted || controller.volume == 0
                    ? '取消静音（M）'
                    : '静音（M）',
                onPressed: controller.toggleMute,
                icon: Icon(
                  controller.muted || controller.volume == 0
                      ? Icons.volume_off
                      : Icons.volume_up,
                ),
              ),
              SizedBox(
                width: 120,
                child: Slider(
                  value: controller.volume.clamp(0, 100),
                  max: 100,
                  onChanged: controller.setVolume,
                ),
              ),
              _controlBarDivider(context),
              const Text('倍速'),
              DropdownButton<double>(
                // 去掉框架默认下划线：那是 Material 2 的遗留装饰，
                // 在已经设计过的深色纱上像一条莫名的横线。
                // craft-floor 点名的正是这一类"你没画的那些部分也在承载设计"。
                underline: const SizedBox.shrink(),
                value: _nearestRate(controller.rate),
                items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                    .map(
                      (rate) => DropdownMenuItem(
                        value: rate,
                        child: Text('${rate.toString()}x'),
                      ),
                    )
                    .toList(),
                onChanged: (rate) {
                  if (rate != null) controller.setRate(rate);
                },
              ),
              if (request.playLines.length > 1)
                DropdownButton<String>(
                  underline: const SizedBox.shrink(),
                  value: request.flag,
                  hint: const Text('线路'),
                  items: request.playLines
                      .map(
                        (line) => DropdownMenuItem(
                          value: line.flag,
                          child: Text(line.displayName),
                        ),
                      )
                      .toList(),
                  onChanged: (flag) {
                    if (flag != null) onSelectLine(flag);
                  },
                ),
              if (episodes.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _showEpisodes(context, episodes),
                  icon: const Icon(Icons.list, size: 18),
                  label: Text('剧集（${episodes.length}）'),
                ),
              // 轨道与显示类控件**不在这里**：它们归顶栏（字幕轨、弹幕开关，
              // 顶栏常驻所以更易够到）与顶栏的「更多」菜单（字幕样式 / 弹幕设置 /
              // 画面比例与缩放 / 媒体信息）。
              //
              // 原来这两条栏有 **5 个动作重复**（字幕轨、字幕样式、弹幕设置、
              // 画面比例、媒体信息），加上各自十几个同尺寸图标，用户扫视时
              // 找不到落点（用户反馈 2026-10-11「接着处理底部控制条」）。
              // 原则是**一个动作只有一个家**：底部栏只做「播放中要碰的」。
              _controlBarDivider(context),
              IconButton(
                tooltip: '全屏（F11）',
                onPressed: onToggleFullscreen,
                icon: const Icon(Icons.fullscreen),
              ),
              if (liveStatus != null || liveOnline != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.podcasts, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        [
                          ?liveStatus,
                          if (liveOnline != null) '在线 $liveOnline',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (controller.videoWidth != null ||
                  controller.selectedVideoTrack != null)
                Tooltip(
                  message: '媒体信息',
                  child: Text(
                    _mediaSummary(controller),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Text(
                '缓冲 ${_formatDuration(controller.buffered)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _nearestRate(double rate) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var best = rates.first;
    for (final candidate in rates) {
      if ((candidate - rate).abs() < (best - rate).abs()) best = candidate;
    }
    return best;
  }

  void _showEpisodes(BuildContext context, List<VodEpisode> episodes) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: 320,
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisExtent: 40,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) => OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              onSelectEpisode(index);
            },
            child: Text(episodes[index].name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }
}
