/// 应用状态：编排配置导入、站点浏览、详情与播放（§4.2 Application Service 层）。
///
/// 约束：
/// - UI 不直接发网络请求，全部经由此处的服务；
/// - 任何失败都转为 [AppError]，由 UI 展示可定位提示，不阻塞界面；
/// - 存储不可用时降级为“无历史/无缓存”，不影响播放（§16.3）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:sqlite3/sqlite3.dart' show Row;

import '../core/android_sync.dart';
import '../core/ai_config.dart';
import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/cat_source.dart';
import '../core/config_loader.dart';
import '../core/config_parser.dart';
import '../core/history_view.dart';
import '../core/http_api.dart';
import '../core/osd_config.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/player_buttons.dart';
import '../core/protocol.dart';
import '../core/proxy_policy.dart';
import '../core/realtime_sync.dart';
import '../core/site_group.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/app_paths.dart';
import '../services/android_bridge_service.dart';
import '../services/android_playback_bridge.dart';
import '../services/android_read_client.dart';
import '../services/cat_bundle.dart';
import '../services/cat_runtime.dart';
import '../services/epg_service.dart';
import '../services/log_service.dart';
import '../services/live_service.dart';
import '../services/proxy_server.dart';
import '../services/realtime_sync_engine.dart';
import '../services/search_suggest_service.dart';
import '../services/site_service.dart';
import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../services/spider_router.dart';
import '../services/ai_config_store.dart';
import '../services/storage.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';
import '../services/tmdb_config_store.dart';
import '../services/ui_preferences_store.dart';
import '../services/tmdb_enrichment_service.dart';
import '../services/tmdb_history.dart';
import '../services/tmdb_identity_service.dart';
import '../services/tmdb_season_service.dart';
import '../services/tmdb_service.dart';
import '../services/tmdb_stores.dart';
import 'search_state.dart';
import 'sync_state.dart';
import 'tmdb_state.dart';

const String appVersion = '0.1.0';
const String appBuildFlavor = 'MVP-A (Windows)';

/// 启动诊断信息，用于日志页与验收证据（§20.3 “启动日志记录版本、平台、
/// 架构、播放器引擎和运行时版本”）。
class StartupInfo {
  const StartupInfo({
    required this.version,
    required this.flavor,
    required this.platform,
    required this.architecture,
    required this.playerEngine,
    required this.dartVersion,
    required this.configDir,
    required this.cacheDir,
    required this.logDir,
    required this.databasePath,
    this.databaseError,
    this.startupLatency = Duration.zero,
  });

  final String version;
  final String flavor;
  final String platform;
  final String architecture;
  final String playerEngine;
  final String dartVersion;
  final String configDir;
  final String cacheDir;
  final String logDir;
  final String databasePath;
  final String? databaseError;
  final Duration startupLatency;

  String get oneLine =>
      'WebHTV PC $version ($flavor) platform=$platform arch=$architecture '
      'player=$playerEngine dart=$dartVersion '
      'startup=${startupLatency.inMilliseconds}ms';

  String get detailLines => [
    oneLine,
    'config=$configDir',
    'cache=$cacheDir',
    'logs=$logDir',
    'db=$databasePath${databaseError == null ? "" : " (降级: $databaseError)"}',
  ].join('\n');
}

/// 单个页面的加载状态。
enum LoadPhase { idle, loading, ready, failed }

/// 站点列表项的运行时可用性展示（§8.1）。
class SiteListItem {
  const SiteListItem({required this.site, required this.availability});

  final Site site;
  final SiteAvailability availability;
}

/// 应用状态。
class AppState extends ChangeNotifier implements SyncStateHost {
  AppState({
    AppPaths? paths,
    LogService? log,
    String? sidecarHostPath,
    String? jsSidecarHostPath,
    String? jvmSidecarHostPath,
    LiveService? liveService,
    EpgService? epgService,
    AndroidBridgeService? androidBridgeService,
    AndroidPlaybackBridge? androidPlaybackBridge,
    SyncClient? syncClient,
    SyncServer Function(SyncServerHost host)? syncServerFactory,

    /// 测试注入的实时定时器工厂（`null` = 真实 `Timer`）。
    ///
    /// 与 `syncServerFactory` 同一模式：单测不能创建真实定时器，
    /// 否则用例结束就残留（`design/04` G12）。
    RealtimeScheduler? realtimeScheduler,

    /// 测试注入的安卓只读客户端（`null` = 真实 HTTP）。
    ///
    /// widget 测试不得做真实局域网 I/O，只能靠它接管路径 A 的读取与心跳。
    AndroidReadClient? androidReadClient,

    /// 测试注入的站点 HTTP 客户端（widget/单测不可做真实 socket I/O）。
    /// 与 [liveService]/[epgService] 同一模式：只为可测性开一个口子。
    http.Client? httpClient,

    /// 测试注入的联想/热搜服务（避免单测打真实外网）。
    SearchSuggestService? searchSuggestService,
  }) : paths = paths ?? AppPaths.resolve(),
       log = log ?? LogService(),
       _injectedLiveService = liveService,
       _injectedEpgService = epgService,
       _injectedBridgeService = androidBridgeService,
       _injectedSyncClient = syncClient,
       _injectedSyncServerFactory = syncServerFactory,
       _injectedReadClient = androidReadClient,
       _injectedSearchSuggestService = searchSuggestService {
    if (httpClient != null) _httpClient = HttpApiClient(client: httpClient);
    final cacheDir = this.paths.cacheDir;
    _supervisor = SpiderHostSupervisor(
      workRoot: p.join(cacheDir, 'sidecars'),
      log: this.log,
    );
    _spiderRegistry = SpiderManifestRegistry(
      root: p.join(this.paths.configDir, 'spiders'),
      log: this.log,
    );
    // `csp_*` 站点的桌面 jar 缓存：`<config>/spiders/csp/<siteKey>/`（§9.3、ADR-0002）。
    // 与 manifest 注册表同根，但独立子目录：两种站源形态的入口解析规则不同。
    _cspBinding = CspJvmBinding(
      root: p.join(this.paths.configDir, 'spiders', 'csp'),
    );
    _proxy = LocalProxyServer(log: this.log);
    _androidPlaybackBridge =
        androidPlaybackBridge ?? AndroidPlaybackBridge(log: this.log);
    // 安卓接入与同步（Phase 5）：只装配，不自动启动服务端（P3 默认关闭）。
    syncState = SyncState(
      log: this.log,
      host: this,
      settingsPath: this.paths.settingsPath,
      bridgeService: _injectedBridgeService,
      client: _injectedSyncClient,
      serverFactory: _injectedSyncServerFactory,
      readClient: _injectedReadClient,
      realtimeScheduler: realtimeScheduler,
    );
    // 把同步状态的变化**转发**到 AppState 自己的监听者。
    //
    // 为什么必须转发：`SettingsPage` 是 `StatelessWidget`，只读 `state.syncState`
    // 但自身不监听；壳层只监听 `AppState`。若不同步，启动时的**自动接入**（在壳层
    // post-frame 里异步完成）不会触发任何重建，用户看到的是设置页还写着「未接入」
    // 而顶栏已经切到「安卓桥接」（用户反馈 2026-10-09：
    // 「重新打开后是自动接入了但是设置页面的状态没有及时更新」）。
    // `AndroidSettingsPage` 自己 `addListener` 所以它是新的，正是这个差异暴露了缺口。
    syncState.addListener(notifyListeners);
    _catBundle = CatBundle(rootDir: p.join(this.paths.dataDir, 'catbundle'));
    // TMDB 服务：配置引用是函数（设置页保存后无需重建服务）。
    _tmdbService = TmdbService(config: () => _tmdbConfigStore.config);
    final node = SidecarRuntimeResolver.resolve('node');
    if (node != null) {
      _catRuntime = CatNodeRuntime(nodeCommand: node, log: this.log);
      _catPipeline = CatImportPipeline(
        bundle: _catBundle,
        runtime: _catRuntime!,
        log: this.log,
      );
      _importService = ConfigImportService(catResolver: _catPipeline!.resolve);
    }
    _router = SpiderRouter(
      client: _httpClient,
      globalHeaders: const [],
      catHttpClient: _catHttpClient,
      registry: _spiderRegistry,
      supervisor: _supervisor,
      log: this.log,
      hostPath: sidecarHostPath ?? defaultSidecarHostPath(),
      jsHostPath: jsSidecarHostPath ?? defaultJsSidecarHostPath(),
      jvmHostPath: jvmSidecarHostPath ?? defaultJvmSidecarHostPath(),
      cspBinding: _cspBinding,
    );
  }

  final AppPaths paths;
  final LogService log;

  /// 猫源 bundle 下载/缓存（§9 猫源）。
  late final CatBundle _catBundle;

  /// 猫源 Node 运行时；未安装 Node 时为 null（UI 如实报错，不静默跳过）。
  CatNodeRuntime? _catRuntime;

  /// 猫源导入门面；未安装 Node 时为 null。
  CatImportPipeline? _catPipeline;

  late final ConfigImportService _importService;
  late HttpApiClient _httpClient = HttpApiClient();
  final CatHttpClient _catHttpClient = CatHttpClient();
  late final SpiderRouter _router;
  late final AndroidPlaybackBridge _androidPlaybackBridge;

  /// 测试注入的直播服务（用于避免 UI 测试在 fake-async 区做真实 socket I/O）。
  final LiveService? _injectedLiveService;

  /// 测试注入的 EPG 服务（同上：widget 测试不可做真实 socket I/O）。
  final EpgService? _injectedEpgService;

  /// 测试注入的安卓桥接服务（widget 测试不可做真实 socket I/O）。
  final AndroidBridgeService? _injectedBridgeService;

  /// 测试注入的同步客户端（同上）。
  final SyncClient? _injectedSyncClient;

  /// 测试注入的服务端工厂（widget 测试需固定到回环与测试端口区间）。
  final SyncServer Function(SyncServerHost host)? _injectedSyncServerFactory;

  /// 测试注入的安卓只读客户端（widget 测试不得做真实局域网 I/O）。
  final AndroidReadClient? _injectedReadClient;

  /// 直播源加载服务（§13.1）。懒加载：未打开直播页前不建立连接。
  LiveService? _liveService;

  /// EPG（电子节目单）服务（§13.1、§13.3）。懒加载，与直播页同生命周期。
  EpgService? _epgService;

  /// sidecar 宿主（§9.8）。按站点隔离进程、限制资源并按指数退避重试。
  late final SpiderHostSupervisor _supervisor;

  /// 本地 Spider manifest 注册表（§9.7）。
  late final SpiderManifestRegistry _spiderRegistry;

  /// `csp_*` 站点的桌面 jar 缓存绑定（§9.3 `tvbox-java-v1`、ADR-0002）。
  late final CspJvmBinding _cspBinding;

  /// 本地代理(§11)。默认只监听 127.0.0.1,按需启动。
  late final LocalProxyServer _proxy;

  /// 本次播放的代理会话（§11.3.1）。
  ProxySession? _proxySession;

  AppDatabase? _database;
  ConfigRecord? _activeRecord;
  AppConfig? _config;
  SiteService? _siteService;

  /// 安卓接入与同步状态（`docs/phase5/design/02`）。
  ///
  /// 默认全部关闭（P3）；设置落在 `<configDir>/settings.json` 的 `sync` 段
  /// （与 TMDB 同一份文件，各自保留对方的值）。
  late final SyncState syncState;

  StartupInfo? _startupInfo;
  LoadPhase _configPhase = LoadPhase.idle;
  LoadPhase _contentPhase = LoadPhase.idle;
  LoadPhase _detailPhase = LoadPhase.idle;
  AppError? _lastError;
  AppError? _detailError;
  String? _notice;

  Site? _selectedSite;
  SiteResult? _homeResult;
  SiteResult? _categoryResult;
  SiteResult? _detailResult;
  Vod? _selectedVod;
  String? _selectedTypeId;

  /// 当前分类的筛选条件（`filter.key → 选中值`，`§7.4.7`）。
  ///
  /// **切分类时保留**（TVBox/猫影视惯例）：用户选了「2024 年」，换一个分类后
  /// 仍按 2024 筛，而不是让他重新选一遍。仅当**换站点**或**回首页**时清空。
  Map<String, String> _categoryFilters = const {};

  /// 分类分页状态（滚动加载，§7.4.7 分页）。
  ///
  /// 早期实现用「上一页/下一页」按钮，每加载一页就把 `_categoryResult` **整体
  /// 替换**；改成滚动加载后必须把多页**累加**在同一份结果里，否则滚到底加载第 2
  /// 页会把第 1 页从屏幕上抹掉（用户看到列表“跳回顶部且内容变了”）。
  int _categoryPage = 1;
  bool _categoryHasMore = false;
  bool _categoryLoadingMore = false;

  /// 分类请求运行号：切分类 / 换筛选 / 换站点后，在途的下一页响应必须丢弃。
  ///
  /// 没有它时，用户「切到别的分类」与「上一分类第 2 页的响应」会赛跑：迟到
  /// 的追加会把旧分类的内容拼到新分类列表后面。
  int _categoryRunId = 0;

  List<ConfigRecord> _configs = const [];
  String? _importDiagnosticsSummary;

  /// 并发搜索：递增的运行号，用于丢弃被取代批次的结果。
  int _searchRunId = 0;

  /// 详情请求：递增的运行号，用于丢弃被取代请求的结果（§8.3）。
  ///
  /// 详情页是唯一一处把**页面状态放在全局 AppState** 里的地方，用户又经常
  /// 「返回列表 → 立刻点另一部剧」，于是详情请求天然会并发。没有运行号时，
  /// 先返回的响应会被后返回的覆盖，而详情页读的是全局结果，用户就会看到
  /// 上一部剧的信息。
  int _detailRunId = 0;
  MultiSiteSearchOutcome? _activeSearch;
  List<String> _searchHistory = const [];

  /// 分页状态：站点 key → 已加载页数 / 总页数 / 已见页指纹（§14.1 分页搜索）。
  ///
  /// 单个实例跨站点统一管理（上游 `SearchPageState` 同样的形态）：页码与
  /// 「内容重复即耗尽」的判定需要按站点隔离，但生命周期与搜索批次一致。
  final SearchPagingState _searchPaging = SearchPagingState();

  /// 测试注入的联想/热搜服务；null 时懒构造真实实例。
  final SearchSuggestService? _injectedSearchSuggestService;

  /// 联想/热搜服务：首次访问时构造，缓存目录与站点缓存同域。
  SearchSuggestService? _searchSuggestService;

  /// 联想/热搜服务（懒构造，测试可注入）。
  SearchSuggestService get searchSuggestService =>
      _searchSuggestService ??= _injectedSearchSuggestService ??
      SearchSuggestService(
        log: log,
        cacheDir: p.join(paths.cacheDir, 'search'),
      );

  /// 当前生效的搜索相似度阈值（0~100；0 = 不过滤）。
  ///
  /// 默认取 UI 偏好里存的值（未设置时 30，对齐上游安卓）；测试注入也不受影响。
  int get searchSimilarity => _uiPreferences?.searchSimilarity ?? 30;

  /// 当前生效的**搜索并发线程数**（1~100）。
  ///
  /// 对齐上游安卓 `Setting.getSearchThread()`（默认 20，夹在 1~100）：
  /// 并发度直接决定「搜一轮要等多久」，但太高会打满对端或触发限流，
  /// 所以做成设置项而不是写死。
  int get searchThread => _uiPreferences?.searchThread ?? 20;

  /// 最近一次播放决策，供播放器页与日志页展示。
  PlaybackDecision? _lastDecision;

  /// 最近一次播放诊断（§23），供日志页展示与复制。
  PlaybackDiagnostics? _lastDiagnostics;

  // ---------------------------------------------------------------- TMDB
  //
  // 模块边界（`docs/phase4/design/04` §2）：UI 不直接发 TMDB 请求，全部经此处。
  // TMDB 配置落在 `<configDir>/settings.json`（`03` §5.3），**不进配置 JSON**。

  late final TmdbConfigStore _tmdbConfigStore;

  /// AI 配置（`docs/phase6/design/04` §4）。
  ///
  /// 与 `_tmdbConfigStore` 同构（两者都是 `settings.json` 里带凭据的独立段）。
  /// `late final`：在 `bootstrap` 里装配；未 bootstrap 时访问会抛
  /// `LateInitializationError`——与 TMDB 一致（单测走 `attachAiConfigStore`
  /// 或 `bootstrap`）。
  late final AiConfigStore _aiConfigStore;

  /// UI 偏好（最近使用的站点）。在 [bootstrap] 里装配。
  ///
  /// 可空而不是 `late final`：单元测试/工具可能**不调 bootstrap** 就直接
  /// `importConfig` + `selectSite`（实测 `phase2_search_test.dart` 就是这样），
  /// 用 `late final` 会在 `selectSite` 里抛 `LateInitializationError`。
  /// 记住站点只是**锦上添花**，它不可用时应安静降级，而不是把选站点弄崩。
  UiPreferencesStore? _uiPreferences;
  late final TmdbService _tmdbService;
  TmdbIdentityService? _tmdbIdentityService;
  TmdbSeasonService? _tmdbSeasonService;
  TmdbEnrichmentService? _tmdbEnrichmentService;
  TmdbState? _tmdbState;

  /// TMDB 设置（当前生效）。
  TmdbConfig get tmdbConfig => _tmdbConfigStore.config;

  /// AI 配置（`docs/phase6/design/04` §4）。
  AiConfig get aiConfig => _aiConfigStore.config;

  /// AI 服务是否就绪（季度弹窗据此决定 AI 项是分析还是引导去设置）。
  bool get aiReady => aiConfig.isReady;

  /// 持久化 AI 配置。
  ///
  /// 与 `saveTmdbConfig` 同构：写盘失败**不影响**当前会话（store 的内存值已
  /// 生效），但无论如何都通知 UI 重建。
  ///
  /// **API Key 不得进日志**（Global Constraints）：只记脱敏值与就绪状态。
  Future<bool> saveAiConfig(AiConfig config) async {
    final saved = await _aiConfigStore.save(config);
    if (saved) {
      log.info(
        'AI 设置已更新 enabled=${config.enabled} '
        'protocol=${config.protocol} ready=${config.isReady} '
        'key=${config.redactedApiKey}',
        scope: 'ai',
      );
    } else {
      log.warning('AI 设置保存失败（内存已生效）', scope: 'ai');
    }
    notifyListeners();
    return saved;
  }

  /// 测试口子：不经 bootstrap 直接装配 AI 配置 store。
  ///
  /// 与 [attachUiPreferences] 同理（单测不调 bootstrap）。
  /// 生产代码不得调用；bootstrap 是唯一的正规装配点。
  @visibleForTesting
  void attachAiConfigStore(AiConfigStore store) {
    _aiConfigStore = store;
  }

  /// TMDB 服务（纯 TMDB 详情页直接使用，`04` §6）。
  TmdbService get tmdbService => _tmdbService;

  /// 设置文件路径（设置页展示用）。
  String get tmdbSettingsPath => paths.settingsPath;

  /// TMDB 配置版本号（设置变更时递增，供 UI 重建）。
  int _tmdbConfigRevision = 0;
  int get tmdbConfigRevision => _tmdbConfigRevision;

  /// 当前生效的 TMDB 配置 ID（多配置隔离，`02` §14 Q2）。
  int get tmdbConfigId => _activeRecord?.id ?? 0;

  StartupInfo? get startupInfo => _startupInfo;
  LoadPhase get configPhase => _configPhase;
  LoadPhase get contentPhase => _contentPhase;
  LoadPhase get detailPhase => _detailPhase;
  AppError? get lastError => _lastError;
  String? get notice => _notice;
  AppConfig? get config => _config;
  SiteService? get siteService => _siteService;

  /// 当前配置声明的直播源（§7.1 `lives`）。
  List<LiveSource> get liveSources => _config?.lives ?? const [];

  /// 直播服务（§13.1）。首次访问时构造，复用同一个 HttpClient 与缓存。
  LiveService get liveService =>
      _liveService ??= _injectedLiveService ?? LiveService();

  /// EPG 服务（§13.1）。缓存落在 `paths.cacheDir/epg/`，与直播服务同域。
  EpgService get epgService => _epgService ??=
      _injectedEpgService ?? EpgService(cacheDir: paths.cacheDir);
  AppDatabase? get database => _database;
  ConfigRecord? get activeRecord => _activeRecord;
  List<ConfigRecord> get configs => _configs;
  Site? get selectedSite => _selectedSite;
  SiteResult? get homeResult => _homeResult;
  SiteResult? get categoryResult => _categoryResult;
  SiteResult? get detailResult => _detailResult;
  Vod? get selectedVod => _selectedVod;
  String? get selectedTypeId => _selectedTypeId;

  /// 当前生效的分类筛选条件（供 UI 高亮选中项）。
  Map<String, String> get categoryFilters => _categoryFilters;

  /// 当前分类已加载到第几页（滚动加载下一页的基准）。
  int get categoryPage => _categoryPage;

  /// 当前分类是否还有下一页（false 时滚动到底不再请求）。
  bool get categoryHasMore => _categoryHasMore;

  /// 是否正在加载「下一页」（滚动时防止同一页码被并发请求多次）。
  bool get categoryLoadingMore => _categoryLoadingMore;

  /// 详情错误（与首页/分类/搜索共用的 [lastError] 分开）。
  ///
  /// 详情页可能叠在浏览页之上，而浏览页会渲染 `lastError`：详情失败若写进
  /// 同一个字段，用户返回列表时会看到一条与当前列表无关的详情错误横幅。
  AppError? get detailError => _detailError;
  String? get importDiagnosticsSummary => _importDiagnosticsSummary;
  PlaybackDecision? get lastDecision => _lastDecision;

  /// 最近一次播放诊断快照（§23）。
  PlaybackDiagnostics? get lastDiagnostics => _lastDiagnostics;

  /// 记录一次播放诊断（由播放器页在加载完成后调用），供日志页展示。
  void recordPlaybackDiagnostics(PlaybackDiagnostics diagnostics) {
    _lastDiagnostics = diagnostics;
    notifyListeners();
  }

  /// 当前（或最近一次）并发搜索批次。
  MultiSiteSearchOutcome? get activeSearch => _activeSearch;

  /// 最近搜索关键词（去重、最新在前）。
  ///
  /// 命名与 [searchHistory]（按关键词查播放历史的方法）区分，避免两者混淆。
  List<String> get recentSearchKeywords => _searchHistory;

  /// 读取某部作品上次使用的播放器画面模式。
  String? playerVideoFitModeFor({
    required String siteKey,
    required String vodId,
  }) {
    final value = _uiPreferences?.videoFitMode(siteKey: siteKey, vodId: vodId);
    return value == null || value.isEmpty ? null : value;
  }

  /// 持久化某部作品的播放器画面模式，失败不影响当前播放。
  void rememberPlayerVideoFitMode({
    required String siteKey,
    required String vodId,
    required String mode,
  }) {
    unawaited(
      _uiPreferences?.rememberVideoFitMode(
            siteKey: siteKey,
            vodId: vodId,
            mode: mode,
          ) ??
          Future<void>.value(),
    );
  }

  /// 生效的屏显开关。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认表，不让屏显失败——
  /// 与 [themeMode] 同一口径。
  Map<String, bool> get osdFlags =>
      _uiPreferences?.osdFlags ?? defaultOsdFlags();

  /// 持久化单项屏显开关。
  ///
  /// 写盘失败不影响当前会话（内存里已生效），但无论如何都通知 UI 重建——
  /// 用户刚点了开关，界面必须立刻反映选择（与 [setThemeMode] 同语义）。
  Future<bool> setOsdFlag(String id, bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberOsdFlag(id, enabled);
    notifyListeners();
    return ok;
  }

  /// 生效的播放器按钮顺序。
  List<String> get playerButtonOrder =>
      _uiPreferences?.buttonOrder ?? defaultButtonOrder();

  /// 生效的播放器按钮隐藏集。
  Set<String> get playerButtonHidden =>
      _uiPreferences?.buttonHidden ?? const <String>{};

  /// 持久化播放器按钮顺序。
  Future<bool> setPlayerButtonOrder(List<String> order) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonOrder(order);
    notifyListeners();
    return ok;
  }

  /// 持久化播放器按钮隐藏集。
  Future<bool> setPlayerButtonHidden(Set<String> hidden) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonHidden(hidden);
    notifyListeners();
    return ok;
  }

  /// 恢复播放器按钮排版默认。
  Future<bool> resetPlayerButtons() async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.resetPlayerButtons();
    notifyListeners();
    return ok;
  }

  /// 主题模式（`dark` / `light` / `system`）。
  ///
  /// 这一层只暴露原始字符串、不暴露 Flutter 的 `ThemeMode`：状态层目前只依赖
  /// `foundation`，不为一个枚举把 `material` 拉进来。映射放在 `app.dart`。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认暗色，不让主题失败。
  String get themeMode => _uiPreferences?.themeMode ?? UiThemeMode.dark;

  /// 用户是否**显式选过**主题。设置页据此区分"跟随系统"与"从未选过"。
  bool get hasExplicitThemeMode =>
      _uiPreferences?.hasExplicitThemeMode ?? false;

  /// 持久化主题模式。
  ///
  /// 写盘失败不影响当前会话（内存里已生效），但无论如何都通知 UI 重建——
  /// 用户刚点了开关，界面必须立刻反映选择。
  Future<bool> setThemeMode(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberThemeMode(mode);
    notifyListeners();
    return ok;
  }

  /// 点击历史记录的行为（`docs/phase6/design/01` §4）：`detail` 进详情页 /
  /// `play` 直接播放。
  ///
  /// 与 [themeMode] 同构：这一层只暴露原始字符串，归一化由 store 负责，
  /// UI 只依赖 `AppState`。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认 `detail`，
  /// 不让历史页因偏好未装配而崩。
  String get historyClickAction =>
      _uiPreferences?.historyClickAction ?? UiHistoryClickAction.detail;

  /// 持久化点击历史行为。
  ///
  /// 与 [setThemeMode] 同构：`store` 会把非法值归一到 `detail`，写盘失败不影响
  /// 当前会话（内存里已生效），但无论如何都通知 UI 重建。
  Future<bool> setHistoryClickAction(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberHistoryClickAction(mode);
    notifyListeners();
    return ok;
  }

  /// 测试口子：不经 bootstrap 直接装配 UI 偏好 store。
  ///
  /// 与 `_uiPreferences` 可空的原因相同（见字段注释）：单测不调 bootstrap。
  /// 生产代码不得调用；bootstrap 是唯一的正规装配点。
  @visibleForTesting
  void attachUiPreferences(UiPreferencesStore store) {
    _uiPreferences = store;
    // 搜索历史与偏好同源（bootstrap 里同此逻辑）。
    _searchHistory = store.searchKeywords;
  }

  bool get hasConfig => _config != null && _config!.sites.isNotEmpty;

  /// 站点列表(含运行时可用性),隐藏 `hide=1` 的站点。
  ///
  /// 使用实例级 [SpiderRouter.classifySite] 而非静态 [SpiderRouter.classify],
  /// 才能对 `spider-local:` 站点给出真实可用性(§8.1、§9.7)。
  List<SiteListItem> get siteItems {
    final config = _config;
    if (config == null) return const [];
    return config.sites
        .where((site) => !site.hide)
        .map(
          (site) => SiteListItem(
            site: site,
            // §8.1:可用性判定必须区分「运行时未安装」与「站点不可用」,
            // 因此这里用带注册表的实例方法，而不是静态 `classify`。
            availability: _router.classifySite(site),
          ),
        )
        .toList();
  }

  /// 当前配置里可用于**搜索范围限定**的分组（按站点顺序去重）。
  ///
  /// 与结果页的分组筛选不同：范围选择发生在搜索**之前**，因此分组来源必须是
  /// 整个配置（上游 `Site.getGroups(VodConfig.get().getSites())`），不能只从
  /// 上次结果里推导。只统计可搜索且未隐藏的站点。
  List<String> get searchScopeGroups {
    final seen = <String>[];
    for (final item in siteItems) {
      if (!item.site.searchable) continue;
      for (final group in siteGroupsOf(item.site.name)) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  /// 启动：目录、日志、数据库、上一个配置。
  ///
  /// 任一步骤失败都记录日志并继续，保证“数据库异常不影响播放器启动”（§16.3）。
  Future<void> bootstrap() async {
    final stopwatch = Stopwatch()..start();
    final directoryFailures = await paths.ensureDirectories();
    if (directoryFailures.isNotEmpty) {
      log.warning('部分目录创建失败：${directoryFailures.join("; ")}');
    }

    LogService.logDirectoryOverride = paths.logDir;
    await log.open(paths.logDir);

    // 安卓接入与同步设置（Phase 5）：读取失败不阻塞启动，退回默认（全关）。
    await syncState.load();

    // TMDB 设置（`03` §5.3）：读取失败不阻塞启动，退回默认配置。
    _tmdbConfigStore = TmdbConfigStore(path: paths.settingsPath, log: log);
    await _tmdbConfigStore.load();

    // AI 配置（`docs/phase6/design/04` §4）：同样不阻塞启动。
    _aiConfigStore = AiConfigStore(path: paths.settingsPath, log: log);
    await _aiConfigStore.load();

    // UI 偏好（最近使用的站点）：同样不阻塞启动。
    final uiPreferences = UiPreferencesStore(
      path: paths.settingsPath,
      log: log,
    );
    await uiPreferences.load();
    _uiPreferences = uiPreferences;
    // 搜索历史与偏好同源：启动时从磁盘恢复（上游安卓每次进搜索页都读
    // `Setting.getKeyword()`；PC 端在 bootstrap 恢复一次，后续增删走 store）。
    _searchHistory = uiPreferences.searchKeywords;

    final openResult = AppDatabase.open(paths.databasePath);
    _database = openResult.database;
    if (!openResult.succeeded) {
      log.error('数据库打开失败，降级为无历史模式：${openResult.error}');
    }

    var platform = Platform.operatingSystem;
    var architecture = Platform.version.split(' ').first;
    if (Platform.isWindows) {
      platform = 'windows';
      architecture = _windowsArchitecture();
    }

    if (_database != null) {
      try {
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
        final record = _activeRecord;
        if (record != null && record.json.isNotEmpty) {
          // 猫源配置的站点 `api` 指向本机随机端口，重启后端口已变；必须按保存的
          // 原始猫源地址重新拉起 bundle，而不是直接复用旧 JSON。
          final reserved = await _reserveCatConfig(record.origin);
          _config = reserved ?? parseConfigRecord(record.json);
          _attachSiteService();
          log.info(
            '恢复配置：${record.name} sites=${_config!.sites.length} '
            'cat=${reserved != null} origin=${redactUrl(record.origin)}',
          );
        }
      } catch (error) {
        log.error('恢复已保存配置失败：$error');
        _config = null;
        _activeRecord = null;
      }
    }

    stopwatch.stop();
    _startupInfo = StartupInfo(
      version: appVersion,
      flavor: appBuildFlavor,
      platform: platform,
      architecture: architecture,
      playerEngine: 'media-kit (libmpv)',
      dartVersion: Platform.version,
      configDir: paths.configDir,
      cacheDir: paths.cacheDir,
      logDir: paths.logDir,
      databasePath: paths.databasePath,
      databaseError: openResult.error,
      startupLatency: stopwatch.elapsed,
    );
    log.info(_startupInfo!.oneLine, scope: 'startup');
    log.info(
      _startupInfo!.detailLines.replaceAll('\n', ' | '),
      scope: 'startup',
    );

    _configPhase = hasConfig ? LoadPhase.ready : LoadPhase.idle;
    notifyListeners();
  }

  String _windowsArchitecture() {
    final env = Platform.environment['PROCESSOR_ARCHITECTURE'];
    if (env == null || env.isEmpty) return 'x64';
    switch (env.toLowerCase()) {
      case 'amd64':
        return 'x64';
      case 'arm64':
        return 'arm64';
      case 'x86':
        return 'x86';
      default:
        return env.toLowerCase();
    }
  }

  /// TMDB 状态（`04` §2.2）。首次访问时构造；未配置时构造出的实例
  /// 会进入 `disabled` 阶段，不发起任何请求。
  TmdbState get tmdb => _tmdbState ??= TmdbState(
    config: () => _tmdbConfigStore.config,
    service: _tmdbService,
    identityService: _ensureTmdbIdentityService(),
    seasonService: _ensureTmdbSeasonService(),
    enrichmentService: _ensureTmdbEnrichmentService(),
    isCurrentRun: () => _tmdbRunId == _detailRunId,
  );

  /// 当前 TMDB 加载归属的详情运行号（`loadDetail` 每次自增）。
  int _tmdbRunId = 0;

  /// 清除鉴权熔断（仅供测试：注入 401 后需要先清掉上一次的熔断窗口）。
  void clearAuthBlocksForTest() => _tmdbService.clearAuthBlocks();

  /// 用当前详情页上下文重新加载 TMDB 区块（手动匹配 / 重新匹配后调用）。
  Future<void> reloadTmdb() async {
    final vod = _selectedVod;
    final site = _selectedSite;
    if (vod == null || site == null || _database == null) return;
    _tmdbRunId = _detailRunId;
    await tmdb.loadForVod(
      vod,
      siteKey: site.key,
      siteName: site.name,
      configId: tmdbConfigId,
      lines: playLinesOf(vod),
    );
  }

  TmdbIdentityService _ensureTmdbIdentityService() =>
      _tmdbIdentityService ??= TmdbIdentityService(
        config: () => _tmdbConfigStore.config,
        service: _tmdbService,
        store: DatabaseTmdbMatchStore(
          database: _database!,
          configId: tmdbConfigId,
        ),
      );

  TmdbSeasonService _ensureTmdbSeasonService() => _tmdbSeasonService ??=
      TmdbSeasonService(store: DatabaseTmdbSeasonStore(database: _database!));

  TmdbEnrichmentService _ensureTmdbEnrichmentService() =>
      _tmdbEnrichmentService ??= TmdbEnrichmentService(
        service: _tmdbService,
        config: () => _tmdbConfigStore.config,
      );

  /// 切换配置后重建 TMDB 服务，使 `config_id` 隔离生效（`02` §14 Q2）。
  void _resetTmdbServices() {
    _tmdbIdentityService = null;
    _tmdbSeasonService = null;
    _tmdbEnrichmentService = null;
    _tmdbState?.clear();
    _tmdbState = null;
  }

  /// 保存 TMDB 设置（设置页「保存」；原子写，`03` §5.5）。
  Future<bool> saveTmdbConfig(TmdbConfig config) async {
    final saved = await _tmdbConfigStore.save(config);
    if (saved) {
      _tmdbConfigRevision++;
      log.info(
        'TMDB 设置已更新 enabled=${config.enabled} ready=${config.isReady} '
        'lang=${config.language} '
        'key=${config.redactedApiKey} token=${config.redactedAccessToken}',
        scope: 'tmdb',
      );
    } else {
      _lastError = AppError(AppErrorKind.storage, 'TMDB 设置保存失败');
    }
    notifyListeners();
    return saved;
  }

  /// 测试连接（`04` §10.2）：调 `/configuration`，返回结构化结果。
  Future<String> testTmdbConnection() async {
    final config = _tmdbConfigStore.config;
    if (!config.isReady) return '请先填写 API Key 或 Access Token';
    try {
      final detail = await _tmdbService.configuration();
      final images = detail['images'];
      final hasImages = images is Map && images.isNotEmpty;
      return '连接正常（配置字段 ${detail.length} 项'
          '${hasImages ? '，含图片主机配置' : ''}）';
    } on TmdbAuthException catch (error) {
      return '鉴权失败（HTTP ${error.statusCode}）：请检查 Key/Token';
    } on AppError catch (error) {
      return '连接失败：${error.userMessage}';
    } catch (error) {
      return '连接失败：$error';
    }
  }

  /// 手动匹配（`01` §7、`04` §5.1）。成功后刷新详情页 TMDB 区块。
  Future<TmdbMatchOutcome?> matchTmdbManual({
    required TmdbItem item,
    String? sourceTitle,
  }) async {
    final identityService = _tmdbIdentityService;
    final vod = _selectedVod;
    final site = _selectedSite;
    if (identityService == null || vod == null || site == null) return null;
    try {
      final outcome = await identityService.matchManual(
        request: TmdbMatchRequest(
          siteKey: site.key,
          vodId: vod.vodId,
          sourceTitle: sourceTitle ?? vod.vodName,
        ),
        item: item,
      );
      // 重新加载详情页 TMDB 区块（手动结论必须立刻可见）。
      await reloadTmdb();
      return outcome;
    } catch (error) {
      log.warning('手动匹配失败：$error', scope: 'tmdb');
      return null;
    }
  }

  /// 手动季度绑定（`04` §5.2、`02` §8.4）。
  ///
  /// 返回是否真的写入了绑定（参数非法时为 `false`）。
  Future<bool> bindTmdbSeason(TmdbSeasonChoice choice) async {
    final seasonService = _tmdbSeasonService;
    final tmdb = _tmdbState;
    final site = _selectedSite;
    if (seasonService == null || tmdb == null || site == null) return false;
    final item = tmdb.item;
    final line = tmdb.sourceLine;
    final vod = tmdb.vod;
    if (item == null || line == null || vod == null) return false;

    final configId = tmdbConfigId;
    void clear() => seasonService.clearBinding(
      configId: configId,
      siteKey: site.key,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: line.flagKey,
    );

    if (choice is TmdbSeasonAuto) {
      clear();
      log.info('TMDB 季度绑定已清除（回到自动解析）', scope: 'tmdb');
      return true;
    }

    final decoded = bindingModeOf(choice);
    if (decoded == null) {
      clear();
      return true;
    }
    final mode = decoded.mode;
    final seasonNumber = decoded.seasonNumber;
    final binding = seasonService.bindSeason(
      configId: configId,
      siteKey: site.key,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: line.flagKey,
      sourceFlag: line.sourceFlag,
      tmdbId: item.tmdbId,
      mediaType: item.mediaType,
      mode: mode,
      seasonNumber: seasonNumber,
      line: line,
      seasonCounts: tmdb.seasonEpisodeCounts,
      tmdbSeasonEpisodeCount: seasonNumber == null
          ? 0
          : (tmdb.seasonEpisodeCounts[seasonNumber] ?? 0),
    );
    if (binding == null) {
      log.warning('TMDB 季度绑定参数非法，已忽略', scope: 'tmdb');
      return false;
    }
    log.info(
      'TMDB 季度绑定已写入 mode=${mode.name} season=$seasonNumber',
      scope: 'tmdb',
    );
    return true;
  }

  /// 用系统默认浏览器打开外部链接（相关视频，`04` §7.2）。
  ///
  /// 用 `explorer.exe` 而不是 `url_launcher`：后者会为 Windows 引入
  /// `url_launcher_windows` 插件（C++ 插件工程 + CMake 变更），而本阶段
  /// 只需「打开一个 http(s) 地址」，Windows 自带的 `explorer.exe <url>`
  /// 已由系统处理默认浏览器与协议。返回是否成功发起。
  Future<bool> openExternalUrl(String url) async {
    if (!Platform.isWindows) return false;
    try {
      await Process.start('explorer.exe', [
        url,
      ], mode: ProcessStartMode.detached);
      return true;
    } catch (error) {
      log.warning('打开外部链接失败：$error', scope: 'tmdb');
      return false;
    }
  }

  /// TMDB 搜索（手动匹配弹窗用）。
  Future<List<TmdbItem>> searchTmdb(String keyword) async {
    final identityService = _tmdbIdentityService;
    if (identityService == null) return const [];
    try {
      return await identityService.searchCandidates(keyword);
    } catch (error) {
      log.warning('TMDB 搜索失败：$error', scope: 'tmdb');
      return const [];
    }
  }

  /// Provider ID 直达（`tmdb:12345` / `movie:12345` / `tv:12345`）。
  Future<TmdbItem?> resolveTmdbProviderId(String input) async {
    final identityService = _tmdbIdentityService;
    if (identityService == null) return null;
    try {
      return await identityService.resolveProviderId(input);
    } catch (_) {
      return null;
    }
  }

  /// 写入季度进度（`02` §6.2）。
  ///
  /// 来源 `history` 永远写（既有行为不变）；季度投影只在已确证季度时写。
  void recordSeasonProgress({
    required TmdbPlaybackIdentity identity,
    required SeasonScope scope,
    required String siteKey,
    required String vodId,
    required String sourceFlag,
    required String sourceEpisodeName,
    required String sourceEpisodeUrl,
    required int positionMs,
    required int durationMs,
    int segmentSeason = -1,
  }) {
    final seasonService = _tmdbSeasonService;
    final media = identity.identity;
    if (seasonService == null || media == null) return;
    try {
      seasonService.recordProgress(
        configId: tmdbConfigId,
        identity: media,
        scope: scope,
        episodeNumber: identity.episodeNumber,
        positionMs: positionMs,
        durationMs: durationMs,
        sourceFlag: sourceFlag,
        sourceEpisodeName: sourceEpisodeName,
        sourceEpisodeUrl: sourceEpisodeUrl,
        sourceHistoryKey: TmdbHistoryKey.of(
          siteKey: siteKey,
          vodId: vodId,
          flag: sourceFlag,
          episodeUrl: sourceEpisodeUrl,
        ),
        sourceBindingKey: identity.flagKey,
        segmentSeason: segmentSeason < 0 ? null : segmentSeason,
      );
    } catch (error) {
      // 进度写失败不影响播放（§15.2）
      log.warning('写入季度进度失败：$error', scope: 'tmdb');
    }
  }

  /// 读取季度进度（续播，`02` §6.3）。
  TmdbSeasonProgressRecord? findSeasonProgress({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return null;
    try {
      return seasonService.progressFor(
        configId: tmdbConfigId,
        identity: media,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return null;
    }
  }

  /// 全部季度进度（历史投影，`02` §7.1）。
  List<TmdbSeasonProgressRecord> seasonProgressFor(TmdbIdentity media) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return const [];
    try {
      return seasonService.progressList(
        configId: tmdbConfigId,
        identity: media,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 当前配置下的全部季度历史卡片（历史页展示，`02` §7.1）。
  List<SeasonHistoryCard> seasonHistoryCards() {
    final database = _database;
    if (database == null) return const [];
    try {
      final records = database
          .tmdbSeasonProgressAll(configId: tmdbConfigId)
          .map((row) => _seasonProgressFromRow(row))
          .toList();
      return projectSeasonHistory(records);
    } catch (error) {
      log.warning('读取季度历史失败：$error', scope: 'tmdb');
      return const [];
    }
  }

  static TmdbSeasonProgressRecord _seasonProgressFromRow(Row row) =>
      TmdbSeasonProgressRecord(
        configId: row['config_id'] as int? ?? 0,
        mediaType: row['media_type'] as String? ?? 'tv',
        tmdbId: row['tmdb_id'] as int? ?? 0,
        seasonNumber: row['season_number'] as int? ?? 0,
        episodeNumber: row['episode_number'] as int? ?? 0,
        positionMs: row['position_ms'] as int? ?? 0,
        durationMs: row['duration_ms'] as int? ?? 0,
        sourceFlag: row['source_flag'] as String? ?? '',
        sourceEpisodeName: row['source_episode_name'] as String? ?? '',
        sourceEpisodeUrl: row['source_episode_url'] as String? ?? '',
        sourceHistoryKey: row['source_history_key'] as String? ?? '',
        sourceBindingKey: row['source_binding_key'] as String? ?? '',
        updatedAt: row['updated_at'] as int? ?? 0,
      );

  /// 同季度换源候选（`02` §7.3）。
  List<RouteBinding> seasonRouteCandidates({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return const [];
    try {
      return seasonService.candidatesForSeason(
        configId: tmdbConfigId,
        identity: media,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 删除某一季度历史（`02` §7.4 一级操作）。
  int deleteSeasonProgress({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return 0;
    final removed = seasonService.deleteSeasonHistory(
      configId: tmdbConfigId,
      identity: media,
      seasonNumber: seasonNumber,
    );
    notifyListeners();
    return removed;
  }

  /// 删除整部节目历史（`02` §7.4 **二级操作**）。
  int deleteMediaProgress(TmdbIdentity media) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return 0;
    final removed = seasonService.deleteMediaHistory(
      configId: tmdbConfigId,
      identity: media,
    );
    notifyListeners();
    return removed;
  }

  void _attachSiteService() {
    final config = _config;
    if (config == null) {
      _siteService = null;
      return;
    }
    _siteService = SiteService(
      appConfig: config,
      playbackBridge: _androidPlaybackBridge,
      router: SpiderRouter(
        client: _httpClient,
        globalHeaders: config.headers,
        catHttpClient: _catHttpClient,
        registry: _spiderRegistry,
        supervisor: _supervisor,
        log: log,
        hostPath: _router.hostPath ?? defaultSidecarHostPath(),
        jsHostPath: defaultJsSidecarHostPath(),
        jvmHostPath: defaultJvmSidecarHostPath(),
        cspBinding: _cspBinding,
      ),
      database: _database,
    );
    // 选中站点必须属于当前配置：`??=` 会在导入新配置时保留上一个配置的站点
    // （实测：导入猫源后仍选中旧配置的 `csp_PianDan`，首页直接 siteUnsupported，
    // 用户看到「一个站点都加载不出数据」）。因此按 key 校验归属，不属于当前配置
    // 的选中项一律作废，退回当前配置的默认站点。
    final selected = _selectedSite;
    if (selected != null && !_configContainsSite(config, selected)) {
      _selectedSite = null;
    }
    // 恢复**最近一次使用的站点**（用户需求 2026-10-10）：重启后默认回到它，
    // 而不是每次都被重置到配置里的第一个站点。
    //
    // 三重守卫，避免「恢复出一个不该用的站点」：
    // - 该 key 必须仍存在于**当前配置**（换了配置就作废，否则首页必然 siteUnsupported）；
    // - 只在尚未选中时生效（不抢已恢复的 `_selectedSite`）；
    // - 找不到就退回 `config.defaultSite()`（首次使用即此分支）。
    if (_selectedSite == null) {
      final remembered = _siteByKey(config, _uiPreferences?.lastSiteKey ?? '');
      if (remembered != null) {
        _selectedSite = remembered;
        log.info(
          '恢复上次使用的站点 site=${remembered.key.isEmpty ? remembered.name : remembered.key}',
          scope: 'site',
        );
      }
    }
    _selectedSite ??= config.defaultSite();
  }

  /// 按 key（或名称兜底）在当前配置里找站点；找不到返回 `null`。
  static Site? _siteByKey(AppConfig config, String key) {
    final target = key.trim();
    if (target.isEmpty) return null;
    for (final candidate in config.sites) {
      if (candidate.hide) continue;
      if (candidate.key == target || candidate.name == target) return candidate;
    }
    return null;
  }

  /// 当前配置里是否存在同一个站点（按 key 比对；key 为空时按 name）。
  static bool _configContainsSite(AppConfig config, Site site) {
    for (final candidate in config.sites) {
      if (candidate.key.isNotEmpty && candidate.key == site.key) return true;
      if (candidate.key.isEmpty && candidate.name == site.name) return true;
    }
    return false;
  }

  /// 若保存的配置来源是猫源 bundle，则按原始地址重新拉起本机 Node 并取回新端口配置。
  ///
  /// 猫源站点 `api` 指向本机随机端口，重启后端口必变，因此**不能**直接复用旧 JSON
  /// 里的 api（会指向已经关掉的旧端口）。重拉失败时返回 null，调用方回退到旧 JSON，
  /// 由站点页如实报告不可用，而不是把整次启动拖垮。
  Future<AppConfig?> _reserveCatConfig(String origin) async {
    final pipeline = _catPipeline;
    if (pipeline == null || !CatSource.isBundle(origin)) return null;
    try {
      final resolved = await pipeline.resolve(origin);
      if (resolved == null) return null;
      final document = parseConfigDocument(resolved.configJson);
      return document.config;
    } catch (error) {
      log.warning('猫源重启失败，回退到已保存配置：$error', scope: 'cat');
      return null;
    }
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  /// 注入一份详情状态，仅供 widget 测试使用（fake-async 区无法跑真实网络）。
  ///
  /// 详情页渲染归属的 UI 门禁需要「全局残留一份属于别的剧的结果」或「正在加载」
  /// 这类前提，而 `testWidgets` 的 fake-async 区推不动真实 HTTP（框架会把请求
  /// 固定返回 400），因此提供一个显式的测试注入点，而不是让生产代码为测试妥协。
  @visibleForTesting
  void seedDetailForTest({
    Vod? vod,
    LoadPhase phase = LoadPhase.ready,
    AppError? error,
  }) {
    _detailResult = vod == null ? null : SiteResult(list: [vod]);
    _selectedVod = vod;
    _detailPhase = phase;
    _detailError = error;
    notifyListeners();
  }

  /// 注入一份首页/分类结果，仅供 widget 测试使用（同 [seedDetailForTest]）。
  ///
  /// 海报网格的门禁需要「给定一批条目 → 断言卡片渲染了什么」这类前提，
  /// 而 fake-async 区拿不到真实站点数据，因此提供显式注入点。
  @visibleForTesting
  void seedListingForTest(List<Vod> list) {
    _homeResult = SiteResult(list: list);
    _selectedTypeId = null;
    _contentPhase = LoadPhase.ready;
    _lastError = null;
    notifyListeners();
  }

  /// 回到站点首页的“默认推荐”列表：清空当前分类筛选，显示首页结果。
  void selectDefaultListing() {
    _selectedTypeId = null;
    _categoryResult = null;
    _resetCategoryPaging();
    // 回首页意味着离开分类上下文，筛选条件随之作废（否则回到首页再选分类会带着旧筛选）。
    _categoryFilters = const {};
    notifyListeners();
  }

  /// 导入配置（URL / 文件路径 / JSON 文本）。
  ///
  /// 失败时**不覆盖**已有配置（§7.4.1、§7.5），并保留可定位错误。
  Future<bool> importConfig(String input, {String? displayName}) async {
    _configPhase = LoadPhase.loading;
    _lastError = null;
    _importDiagnosticsSummary = null;
    notifyListeners();

    try {
      final source = ConfigSource.parse(input);
      var imported = await _importService.import(source);
      var repositoryIndex = 0;

      if (imported.isRepository) {
        // §7.4.2：默认第一项；切换条目时保留各条目独立配置记录。
        log.info(
          '导入配置仓库 entries=${imported.repositoryEntries.length} '
          'origin=${redactUrl(imported.origin)}',
        );
        imported = await _importService.expandRepository(imported);
      }

      final config = imported.config;
      if (config == null) {
        throw AppError(
          AppErrorKind.configInvalid,
          '导入结果没有可用配置',
          detail: redactUrl(imported.origin),
        );
      }

      _config = config;
      _importDiagnosticsSummary = imported.diagnostics.isEmpty
          ? null
          : imported.diagnostics.join('；');
      // 旧配置的详情请求必须作废：配置换了之后返回的详情属于另一个站点
      // （§7.4.1 导入即切换）。
      _detailRunId++;
      // 选中站点必须属于新配置（§7.4.1 导入即切换）：`_attachSiteService` 会按 key
      // 校验归属，不属于当前配置的选中项退回新配置的默认站点。
      //
      // 注意不能无条件置空：用户重新导入**同一份**配置（刷新）时应留在原站点；
      // 也不能继续用 `??=`：实测导入猫源后仍选中旧配置的 `csp_PianDan`，首页直接
      // siteUnsupported，用户看到「一个站点都加载不出数据」。
      final previousSiteKey = _selectedSite?.key;
      _attachSiteService();
      // 浏览结果绑定在选中站点上：站点换了就必须丢弃，否则拿旧站点列表渲染新配置。
      if (_selectedSite?.key != previousSiteKey) {
        _selectedTypeId = null;
        _homeResult = null;
        _categoryResult = null;
        _detailResult = null;
        _detailError = null;
        _activeSearch = null;
        // 筛选维度是**站点相关**的（不同站点的 key/取值完全不同），换站点必须
        // 一并作废：留着旧站点的筛选会让新站点的第一个分类请求带着无效的 ext。
        _categoryFilters = const {};
        _resetCategoryPaging();
      }

      final name = displayName ?? config.name ?? source.displayName;
      final recordId = _database?.saveConfig(
        name: name,
        origin: imported.origin,
        json: config.toJson(),
        contentType: imported.contentType,
        repositoryIndex: repositoryIndex,
        repositoryEntries: imported.repositoryEntries,
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        makeActive: true,
      );
      if (recordId != null) {
        _database!.saveConfigSites(recordId, config.sites);
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
      }

      _notice = config.notice ?? '配置导入成功：${config.sites.length} 个站点';
      _configPhase = LoadPhase.ready;
      log.info(
        '配置导入成功 name=$name sites=${config.sites.length} '
        'lives=${config.lives.length} headers=${config.headers.length} '
        'origin=${redactUrl(imported.origin)}',
        scope: 'config',
      );
      if (_importDiagnosticsSummary != null) {
        log.warning('导入诊断：$_importDiagnosticsSummary', scope: 'config');
      }
      notifyListeners();

      // 导入后自动加载默认站点首页，形成“导入 → 首页”的闭环。
      final site = _selectedSite;
      if (site != null) {
        await loadHome(site);
      }
      return true;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _configPhase = hasConfig ? LoadPhase.ready : LoadPhase.failed;
      log.error('配置导入失败：${failure.logLine}', scope: 'config');
      notifyListeners();
      return false;
    }
  }

  /// 切换到已保存的配置（§7.5 多配置切换）。
  Future<bool> activateConfigRecord(int id) async {
    final database = _database;
    if (database == null) {
      _lastError = AppError(AppErrorKind.storage, '本地存储不可用，无法切换配置');
      notifyListeners();
      return false;
    }
    try {
      database.activateConfig(id);
      _configs = database.listConfigs();
      _activeRecord = database.activeConfig();
      final record = _activeRecord;
      if (record == null || record.json.isEmpty) {
        throw AppError(AppErrorKind.configInvalid, '该配置记录没有可恢复内容');
      }
      // 换源时先终止上一个猫源进程树，再按新记录的原始地址重拉（§9）。
      await _catPipeline?.stop();
      _selectedSite = null;
      final reserved = await _reserveCatConfig(record.origin);
      _config = reserved ?? parseConfigRecord(record.json);
      _attachSiteService();
      _detailRunId++;
      _homeResult = null;
      _categoryResult = null;
      _detailResult = null;
      _detailError = null;
      _categoryFilters = const {};
      _resetCategoryPaging();
      _configPhase = LoadPhase.ready;
      // 切换配置 → 重建 TMDB 服务，使 `config_id` 隔离生效（`02` §14 Q2）。
      _resetTmdbServices();
      log.info('切换配置：${record.name} cat=${reserved != null}', scope: 'config');
      notifyListeners();
      final site = _selectedSite;
      if (site != null) await loadHome(site);
      return true;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      log.error('切换配置失败：${failure.logLine}', scope: 'config');
      notifyListeners();
      return false;
    }
  }

  Future<void> deleteConfigRecord(int id) async {
    final database = _database;
    if (database == null) return;
    database.deleteConfig(id);
    _configs = database.listConfigs();
    if (_activeRecord?.id == id) {
      _activeRecord = database.activeConfig();
      final record = _activeRecord;
      if (record != null && record.json.isNotEmpty) {
        _config = parseConfigRecord(record.json);
        _attachSiteService();
        _detailRunId++;
        _detailResult = null;
        _detailError = null;
      } else {
        _config = null;
        _siteService = null;
        _selectedSite = null;
        _homeResult = null;
        _categoryResult = null;
        _categoryFilters = const {};
        _resetCategoryPaging();
        _detailResult = null;
        _detailError = null;
        _configPhase = LoadPhase.idle;
      }
    }
    notifyListeners();
  }

  /// 选择站点并加载首页。
  Future<void> selectSite(Site site) async {
    // 换站点时作废在途详情请求：旧站点的响应不得覆盖新站点的详情（§8.3）。
    _detailRunId++;
    _selectedSite = site;
    // 记住本次选择：重启后默认回到这个站点（用户需求 2026-10-10）。
    // 写盘失败不影响当前会话（内存已生效），因此不 await 结果。
    // `_uiPreferences` 为 null（未 bootstrap）时安静跳过，不让选站点失败。
    unawaited(
      _uiPreferences?.rememberSite(site.key.isEmpty ? site.name : site.key) ??
          Future<void>.value(),
    );
    _categoryResult = null;
    _detailResult = null;
    _detailError = null;
    _selectedVod = null;
    _selectedTypeId = null;
    // 筛选与分页都是**站点/分类相关**的，换站点必须一起作废（见 _resetCategoryPaging）。
    _categoryFilters = const {};
    _resetCategoryPaging();
    notifyListeners();
    await loadHome(site);
  }

  /// 清空详情页状态（离开详情页时调用，§8.3）。
  ///
  /// 详情结果与所选影片是**绑定在详情页上的临时状态**：不清理的话，用户返回
  /// 列表后再点另一部剧，详情页会先渲染上一个条目的线路，点播即串剧（实测：
  /// 「返回后点其他剧看到的还是这部剧的信息」）。这里同时作废在途请求，避免
  /// 刚离开页面时返回的响应又把状态写回去。
  void clearDetail() {
    _detailRunId++;
    _tmdbRunId = _detailRunId;
    // TMDB 状态是页面级临时状态：不清会让下一次进入详情页先渲染上一部剧的元数据。
    _tmdbState?.clear();
    _detailPhase = LoadPhase.idle;
    _detailResult = null;
    _detailError = null;
    _selectedVod = null;
    notifyListeners();
  }

  /// 加载首页（§8.1、§8.4）。
  /// 加载首页（§8.1、§8.4）。
  ///
  /// 首页无推荐内容时**自动选第一个分类**（用户反馈 2026-10-09：「如果当前站点的
  /// 默认推荐分类无数据时自动隐藏选中显示第一个分类即可」）。
  ///
  /// 为什么：实测 126 个站点里 40 个只返回 `class` 而不返回 `list`，用户进入站点后
  /// 看到的是「请选择一个分类」的空态，必须先手动点一下才有内容——既然站点已经
  /// 给了分类列表，帮用户选第一个是零风险的行为。
  Future<void> loadHome(Site site) async {
    final service = _siteService;
    if (service == null) return;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await service.home(site);
      _homeResult = outcome.value;
      _contentPhase = LoadPhase.ready;
      log.info(
        '首页加载成功 site=${site.key} class=${outcome.value.classes.length} '
        'list=${outcome.value.list.length} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
      // 只在「确实没有推荐内容」且「有分类可选」时才自动选：有推荐内容时不得
      // 抢走用户看到的首页；无分类可退时也不得反复空请求。
      final first = outcome.value.classes.isEmpty
          ? null
          : outcome.value.classes.first;
      if (outcome.value.list.isEmpty && first != null) {
        log.info(
          '首页无推荐内容，自动进入第一个分类 '
          't=${first.typeId} name=${first.typeName}',
          scope: 'site',
        );
        await loadCategory(first.typeId);
        return;
      }
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _contentPhase = LoadPhase.failed;
      log.error('首页加载失败 site=${site.key} ${failure.logLine}', scope: 'site');
    }
    notifyListeners();
  }

  /// 作废分类分页状态（换站点 / 换配置 / 回首页时调用）。
  ///
  /// 递增运行号是必须的：不递增时，「上一个分类下一页」的迟到响应仍会被判定为
  /// 当前请求，把旧列表写回 [_categoryResult]（用户在别的站点上看到旧站点的片单）。
  void _resetCategoryPaging() {
    _categoryRunId++;
    _categoryPage = 1;
    _categoryHasMore = false;
    _categoryLoadingMore = false;
  }

  /// 加载分类（§7.4.7 分页与筛选）。
  ///
  /// 这是「重新开始」路径（[page] 默认 1）：**清空并替换**已有结果。用户实际翻页
  /// 走 [loadMoreCategory]（滚动到底自动追加）。
  ///
  /// [filters] 省略时沿用当前 [_categoryFilters]（**切分类保留筛选**）；
  /// 显式传入（含空表）则覆盖。
  Future<void> loadCategory(
    String typeId, {
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    final effective = filters ?? _categoryFilters;
    // 新一次加载：作废在途的“下一页”响应，避免把上一份列表追加到新列表后面。
    final runId = ++_categoryRunId;
    _selectedTypeId = typeId;
    _categoryFilters = effective;
    _categoryResult = null;
    _categoryPage = page;
    _categoryHasMore = false;
    _categoryLoadingMore = false;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await service.category(
        site,
        typeId: typeId,
        page: page,
        filters: effective,
      );
      if (runId != _categoryRunId) return;
      _categoryResult = outcome.value;
      _categoryPage = page;
      _categoryHasMore = _hasNextPage(outcome.value);
      _contentPhase = LoadPhase.ready;
      log.info(
        '分类加载成功 site=${site.key} t=$typeId page=$page '
        'filters=${effective.isEmpty ? "-" : effective.length} '
        'list=${outcome.value.list.length} '
        'pagecount=${outcome.value.pageCount ?? "-"} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _categoryRunId) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _contentPhase = LoadPhase.failed;
      log.error(
        '分类加载失败 site=${site.key} t=$typeId ${failure.logLine}',
        scope: 'site',
      );
    }
    notifyListeners();
  }

  /// 追加下一页（滚动到底自动触发，§7.4.7）。
  ///
  /// 与 [loadCategory] 的关键差异：
  /// - 旧列表**保留**并追加新页（不先清空），滚动位置不会跳；
  /// - 不加 `_contentPhase = loading`（那是页面级骨架屏），而是置
  ///   [categoryLoadingMore]，避免滚到底时整个网格闪成空白；
  /// - 失败**不写入** `lastError`（不把已经看得见的列表换成错误横幅），
  ///   只记日志并把 `categoryHasMore` 收矮，避免滚动到底反复重试。
  Future<void> loadMoreCategory() async {
    if (_categoryLoadingMore || !_categoryHasMore) return;
    if (_contentPhase == LoadPhase.loading) return;
    final service = _siteService;
    final site = _selectedSite;
    final typeId = _selectedTypeId;
    final current = _categoryResult;
    if (service == null || site == null || typeId == null || current == null) {
      return;
    }
    final runId = _categoryRunId;
    final nextPage = _categoryPage + 1;
    _categoryLoadingMore = true;
    notifyListeners();
    try {
      final outcome = await service.category(
        site,
        typeId: typeId,
        page: nextPage,
        filters: _categoryFilters,
      );
      // 切分类 / 换筛选 / 换站点后到达的响应：直接丢弃（不得拼接）。
      if (runId != _categoryRunId) return;
      final merged = _mergeVods(current.list, outcome.value.list);
      _categoryResult = outcome.value.copyWith(
        list: merged,
        // 分类没有筛选时，站点可能只在首页响应里给筛选维度。追加页的响应
        // 不带 filters，套用会把已有的筛选条抹掉（用户看到“筛选行突然消失”）。
        filters: outcome.value.filters.isEmpty
            ? current.filters
            : outcome.value.filters,
      );
      _categoryPage = nextPage;
      // 到底的判据：本页为空，或本页没有带来任何**新**条目。后者是站点忽略
      // `pg`（反复回同一页）的唯一可靠信号，不接就会无限循环请求同一页。
      _categoryHasMore =
          outcome.value.list.isNotEmpty && merged.length > current.list.length;
      log.info(
        '分类追加成功 site=${site.key} t=$typeId page=$nextPage '
        'added=${outcome.value.list.length} total=${merged.length} '
        'hasMore=$_categoryHasMore elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _categoryRunId) return;
      // 追加失败不抛、不报警：把 hasMore 关掉，用户不再反复触发同一页。
      _categoryHasMore = false;
      log.warning(
        '分类追加失败 site=${site.key} t=$typeId page=$nextPage $error',
        scope: 'site',
      );
    } finally {
      if (runId == _categoryRunId) {
        _categoryLoadingMore = false;
        notifyListeners();
      }
    }
  }

  /// 分类响应是否还有下一页。
  ///
  /// **不得用 `pagecount` / `total`**（实测 2026-10-09，桥接的网盘聚合站
  /// `闪电[盘]`）：同一个分类连续翻页，站点每次回的 `pagecount` 都是
  /// `当前页 + 1`（pg=1 → 2、pg=2 → 3、pg=3 → 4），`total` 同步从 92 涨到
  /// 112、132。这两个字段是上游插件**按当前页现算**的，不表示真实总页数；
  /// 拿它们当判据会让「还有下一页」永远为真，滚动永远加载不完。
  ///
  /// 因此只信内容：拿到非空列表就先假定还有下一页，真正的终止由追加阶段的
  /// 「页面为空 / 没有新增条目」负责。
  static bool _hasNextPage(SiteResult result) => result.list.isNotEmpty;

  /// 合并两页列表，按 `vod_id` 去重（保序：旧页在前）。
  ///
  /// 为什么必须去重：部分站点忽略 `pg` 参数、或末页与前一页有重叠，直接拼接会
  /// 让同一部片重复出现（用户看到列表里“同一张海报连着两张”）。
  static List<Vod> _mergeVods(List<Vod> existing, List<Vod> incoming) {
    final seen = <String>{};
    final merged = <Vod>[];
    for (final vod in [...existing, ...incoming]) {
      if (!seen.add(vod.vodId)) continue;
      merged.add(vod);
    }
    return merged;
  }

  /// 设置/清除单个筛选维度，并**立即重载当前分类**（筛选是即时生效的）。
  ///
  /// [value] 为空串表示清除该维度（对应「全部」选项）。
  Future<void> setCategoryFilter(String key, String value) async {
    final typeId = _selectedTypeId;
    if (typeId == null) return;
    final next = Map<String, String>.from(_categoryFilters);
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    if (_sameFilters(next, _categoryFilters)) return;
    await loadCategory(typeId, filters: next);
  }

  /// 清空全部筛选并重载当前分类。
  Future<void> clearCategoryFilters() async {
    final typeId = _selectedTypeId;
    if (typeId == null || _categoryFilters.isEmpty) return;
    await loadCategory(typeId, filters: const {});
  }

  static bool _sameFilters(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 搜索（§14.1）。
  Future<SiteResult?> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async {
    final service = _siteService;
    if (service == null) return null;
    try {
      final outcome = await service.search(
        site,
        keyword: keyword,
        page: page,
        quick: quick,
      );
      log.info(
        '搜索完成 site=${site.key} wd=$keyword list=${outcome.value.list.length} '
        'cache=${outcome.fromCache} elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'search',
      );
      return outcome.value;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      log.warning('搜索失败 site=${site.key} ${failure.logLine}', scope: 'search');
      rethrow;
    }
  }

  /// 多站点并发搜索（§14.1、§14.3）。
  ///
  /// 行为约束：
  /// - 并发数不超过 [maxConcurrency]（默认取用户的「搜索线程」设置，
  ///   对齐上游 `Setting.getSearchThread`），避免一次性打满网络与对端限流（§14.3）；
  /// - 单站点失败只把该站点标为失败，**不阻塞**其他站点；
  /// - 新查询会让旧查询的在途结果**不再投递**（靠 runId 与 [_activeSearch] 判定）；
  /// - 取消后不再投递任何结果（含在途结果），只保留取消前已发布的快照；
  /// - 结果按配置中的站点顺序稳定排序，重复搜索不改变顺序。
  ///
  /// [siteKey] / [group] 限定搜索范围（对齐上游 SearchFragment 的
  /// 「全部 / 当前站点 / 某分组」）：范围外的站点**既不参与也不算跳过**。
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    String? siteKey,
    String? group,
    int? maxConcurrency,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    final service = _siteService;
    final runId = ++_searchRunId;
    final concurrency = maxConcurrency ?? searchThread;
    final scopeSiteKey = siteKey?.trim() ?? '';
    final scopeGroup = group?.trim() ?? '';
    final allItems = [
      for (final item in siteItems)
        if (_inSearchScope(item.site, scopeSiteKey, scopeGroup)) item,
    ];
    final sites = allItems
        .where((item) => item.availability.available && item.site.searchable)
        .map((item) => item.site)
        .toList();
    final outcome = MultiSiteSearchOutcome(
      runId: runId,
      keyword: keyword,
      results: const [],
      siteKey: scopeSiteKey,
      group: scopeGroup,
      skippedUnsupported: allItems
          .where((item) => !item.availability.available)
          .length,
      skippedNotSearchable: allItems
          .where((item) => item.availability.available && !item.site.searchable)
          .length,
    );
    // 新批次从第 1 页开始：分页状态必须清空，否则会沿用上一批次的页码。
    _searchPaging.clear();
    _activeSearch = outcome;
    _searchHistory = [
      keyword,
      ..._searchHistory.where((item) => item != keyword),
    ].take(20).toList();
    // 持久化搜索历史（上游安卓 `RecordAdapter.add` 落 `Setting.putKeyword`）。
    // 写盘失败不影响当前会话；未 bootstrap（测试路径）时安静跳过。
    unawaited(
      _uiPreferences
              ?.rememberSearchKeyword(keyword)
              .then((_) => null)
              .catchError((_) => null) ??
          Future<void>.value(),
    );
    notifyListeners();

    if (service == null || sites.isEmpty) {
      outcome.finished = true;
      notifyListeners();
      return outcome;
    }

    final entries = <SiteSearchEntry>[];
    var nextIndex = 0;
    final stopwatch = Stopwatch()..start();

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= sites.length) return;
        // 被取消或被更新的查询取代时立即收工：不再发起新请求。
        if (outcome.cancelled || !identical(_activeSearch, outcome)) return;
        final site = sites[index];
        try {
          final value = await service
              .search(site, keyword: keyword, quick: quick, useCache: true)
              .timeout(timeout);
          // 记录初始页的页数与内容指纹（上游 CollectFragment 的
          // `mPaging.recordInitial`）。批次已被取代时不得污染新批次的
          // 分页状态——`_searchPaging` 是跨批次共享的。
          if (!outcome.cancelled && identical(_activeSearch, outcome)) {
            _searchPaging.recordInitial(
              site.key,
              value.value.pageCount ?? 0,
              SearchPagingState.pageTokenOf(value.value.list),
            );
          }
          entries.add(
            SiteSearchEntry(
              siteKey: site.key,
              siteName: site.name,
              groups: siteGroupsOf(site.name),
              result: value.value,
              latency: value.latency,
              fromCache: value.fromCache,
              pageCount: value.value.pageCount ?? 0,
              hasMore: _searchPaging.canLoadMore(site.key),
            ),
          );
        } catch (error) {
          final failure = error is AppError
              ? error
              : AppError(AppErrorKind.unknown, '$error', cause: error);
          entries.add(
            SiteSearchEntry(
              siteKey: site.key,
              siteName: site.name,
              groups: siteGroupsOf(site.name),
              error: failure,
            ),
          );
          log.warning(
            '并发搜索失败 site=${site.key} ${failure.logLine}',
            scope: 'search',
          );
        }
        // 每完成一个站点就更新快照，让 UI 边到边显示。
        // 取消后即便请求刚好返回也**不得投递**（§9.5、§14.1）。
        if (!outcome.cancelled && identical(_activeSearch, outcome)) {
          outcome.update(entries);
          notifyListeners();
        }
      }
    }

    final concurrencyApplied = sites.length < concurrency
        ? sites.length
        : concurrency;
    await Future.wait(List.generate(concurrencyApplied, (_) => worker()));

    if (outcome.cancelled) {
      log.info(
        '搜索批次 run=$runId 已取消，丢弃 ${entries.length} 个在途结果 keyword=$keyword',
        scope: 'search',
      );
      return outcome;
    }

    if (!identical(_activeSearch, outcome)) {
      log.info('搜索批次 run=$runId 已被取代，结果不再投递 keyword=$keyword', scope: 'search');
      return outcome;
    }

    // 按配置顺序稳定排序，避免并发完成顺序导致列表跳动。
    final order = {for (var i = 0; i < sites.length; i++) sites[i].key: i};
    entries.sort(
      (a, b) => (order[a.siteKey] ?? 0).compareTo(order[b.siteKey] ?? 0),
    );
    outcome.update(entries);
    outcome.finished = true;
    outcome.totalElapsed = stopwatch.elapsed;
    log.info(
      '并发搜索完成 run=$runId wd=$keyword sites=${sites.length} '
      'concurrency=$concurrencyApplied '
      'ok=${entries.where((item) => item.succeeded).length} '
      'failed=${entries.where((item) => !item.succeeded).length} '
      'elapsed=${stopwatch.elapsedMilliseconds}ms',
      scope: 'search',
    );
    notifyListeners();
    return outcome;
  }

  /// 取消当前并发搜索（§14.1「可取消搜索」）。
  ///
  /// 只让批次失效；在途请求由各自的 timeout 兜底，且其完成结果不再投递。
  /// 保留 [_activeSearch] 指针，UI 才能显示“已取消”而不是退回空白提示。
  void cancelSearch() {
    final active = _activeSearch;
    if (active == null || active.finished) return;
    active.cancelled = true;
    active.finished = true;
    log.info('并发搜索已取消 run=${active.runId}', scope: 'search');
    notifyListeners();
  }

  /// 清空当前搜索结果，回到「未搜索」状态。
  ///
  /// 为什么需要它（用户 2026-10-14：「搜索之后貌似没办法返回到搜索页面
  /// 默认状态——就是能看到推荐的那些，切换到其他页面再切回来也不行」）：
  /// [_activeSearch] 是**跨页面存活**的（搜索页销毁重建后仍在），而搜索页
  /// 靠它判断要不要显示结果区——于是搜过一次就再也回不到推荐落地页了。
  ///
  /// 与 [cancelSearch] 的区别：后者只把在途批次标为已取消（UI 显示「搜索已
  /// 取消」），而这里把批次整个丢掉，回到干净的未搜索状态。
  void clearSearch() {
    if (_activeSearch == null && !_searchPaging.hasPending) return;
    // 递增运行号：在途批次的结果即便返回也不再投递（否则清空后又被写回）。
    _searchRunId++;
    final runId = _activeSearch?.runId;
    _activeSearch = null;
    _searchPaging.clear();
    log.info('已清空搜索结果 run=${runId ?? "-"}', scope: 'search');
    notifyListeners();
  }

  /// 站点是否落在本次搜索范围内（空条件 = 不限定）。
  bool _inSearchScope(Site site, String siteKey, String group) {
    if (siteKey.isNotEmpty && site.key != siteKey) return false;
    if (group.isNotEmpty && !siteInGroup(site.name, group)) return false;
    return true;
  }

  /// 按 key 取站点（加载更多需要重新拿到站点对象才能发请求）。
  ///
  /// 复用既有的静态 [`_siteByKey`]（它已包含 hide 与名称兜底规则）。
  Site? _searchSiteByKey(String key) {
    final config = _config;
    return config == null ? null : _siteByKey(config, key);
  }

  /// 加载某站点的下一页结果（§14.1「分页搜索」）。
  ///
  /// 对齐上游 `CollectFragment.onLoadMore` + `SearchPageState`：
  /// - 只有当前批次还有效、且该站点已成功且有条目时才允许翻页；
  /// - 同一时刻只允许一个在途翻页（[SearchPagingState.begin] 拒绝重入）；
  /// - **内容与已见过的页重复即判定该站点耗尽**——上游站点常见「越界页码
  ///   返回末页内容」，只看 `page < pageCount` 会永远翻下去；
  /// - 上游未声明总页数（pageCount = 0）时允许一直翻，同样靠内容重复兜底。
  ///
  /// 返回：这次翻页是否**被接受并追加了条目**。UI 用它判断要不要在「相似度
  /// 过滤把整页都滤掉」时自动续翻下一页（上游 `shouldContinue`）。
  Future<bool> loadMoreSearch(
    String siteKey, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final outcome = _activeSearch;
    final service = _siteService;
    if (outcome == null || service == null || outcome.cancelled) return false;
    final entry = outcome.entryOf(siteKey);
    if (entry == null || !entry.succeeded || entry.itemCount == 0) return false;

    final requestedPage = _searchPaging.pageOf(siteKey) + 1;
    if (!_searchPaging.begin(siteKey, requestedPage)) return false;
    final site = _searchSiteByKey(siteKey);
    if (site == null) {
      _searchPaging.cancelPending();
      return false;
    }

    outcome.replaceEntry(entry.copyWith(loadingMore: true));
    notifyListeners();

    try {
      final value = await service
          .search(
            site,
            keyword: outcome.keyword,
            page: requestedPage,
            useCache: true,
            // 分页请求**不得**参与 `(关键词, 站点)` 搜索缓存：那个键只代表第 1 页。
            // 走缓存时实测两个真缺陷：命中第 1 页缓存 → 内容指纹重复被误判
            // 「已耗尽」；以及把第 N 页结果写进第 1 页的缓存键。
            cache: false,
          )
          .timeout(timeout);
      // 批次被取代 / 取消：丢弃结果，但**必须**把在途登记清掉，
      // 否则该站点永远被当成「有在途请求」而无法再翻页。
      if (outcome.cancelled || !identical(_activeSearch, outcome)) {
        _searchPaging.cancelPending();
        return false;
      }
      final completion = _searchPaging.complete(
        hasItems: value.value.list.isNotEmpty,
        pageCount: value.value.pageCount ?? 0,
        pageToken: SearchPagingState.pageTokenOf(value.value.list),
      );
      if (!completion.handled) return false;

      final current = outcome.entryOf(siteKey) ?? entry;
      final hasMore = _searchPaging.canLoadMore(siteKey);
      if (!completion.accepted) {
        // 空页 / 重复页：结果不变，只结束加载态（重复页已在 paging 里标耗尽）。
        outcome.replaceEntry(
          current.copyWith(loadingMore: false, hasMore: hasMore),
        );
        log.info(
          '搜索翻页未追加 site=$siteKey page=$requestedPage '
          'repeated=${completion.repeated} items=${value.value.list.length} '
          'hasMore=$hasMore',
          scope: 'search',
        );
        notifyListeners();
        return false;
      }

      // 追加到已有条目（保留 classes/filters 等无关字段，只换 list 与页码）。
      final merged = (current.result ?? const SiteResult()).copyWith(
        list: [...?current.result?.list, ...value.value.list],
        page: completion.page,
        pageCount: value.value.pageCount ?? current.result?.pageCount,
      );
      outcome.replaceEntry(
        current.copyWith(
          result: merged,
          page: completion.page,
          pageCount: value.value.pageCount ?? current.pageCount,
          loadingMore: false,
          hasMore: hasMore,
        ),
      );
      log.info(
        '搜索翻页成功 site=$siteKey page=${completion.page}'
        '/${value.value.pageCount ?? "?"} added=${value.value.list.length} '
        'total=${merged.list.length} hasMore=$hasMore',
        scope: 'search',
      );
      notifyListeners();
      return true;
    } catch (error) {
      _searchPaging.cancelPending();
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      final current = outcome.entryOf(siteKey) ?? entry;
      outcome.replaceEntry(current.copyWith(loadingMore: false));
      log.warning(
        '搜索翻页失败 site=$siteKey page=$requestedPage ${failure.logLine}',
        scope: 'search',
      );
      notifyListeners();
      return false;
    }
  }

  /// 某站点当前已加载的页数（UI 显示「第 N/M 页」）。
  int searchPageOf(String siteKey) => _searchPaging.pageOf(siteKey);

  // ---------------------------------------------------------------- 搜索辅助
  //
  // 联想 / 热门推荐 / 历史管理（对齐上游安卓默影视 SearchFragment）。UI 只经
  // 这里访问，不直接持 SearchSuggestService。

  /// 搜索联想：输入过程调用，结果含两个上游（爱奇艺 + 腾讯）合并去重。
  Future<List<SearchSuggestItem>> searchSuggest(String keyword) =>
      searchSuggestService.suggest(keyword);

  /// 热门推荐榜单（360kan 电影/剧集/综艺）。
  Future<List<SearchSuggestItem>> searchHotRank(HotRankCategory category) =>
      searchSuggestService.hotRank(category);

  /// 删除单条搜索历史（未 bootstrap 时安静跳过）。
  ///
  /// 先通知、后落盘（乐观更新）：内存是唯一真相，写盘只影响下次启动。
  /// 若把 `notifyListeners` 放在 `await` 之后，落盘一慢/一阻塞 UI 就不更新
  /// （widget 测试里直接表现为删除后 chip 仍在）。
  Future<void> removeSearchKeyword(String keyword) async {
    _searchHistory = [
      for (final item in _searchHistory)
        if (item != keyword) item,
    ];
    notifyListeners();
    final store = _uiPreferences;
    if (store != null) await store.removeSearchKeyword(keyword);
  }

  /// 清空搜索历史。同样先通知、后落盘。
  Future<void> clearSearchHistory() async {
    _searchHistory = const [];
    notifyListeners();
    final store = _uiPreferences;
    if (store != null) await store.clearSearchKeywords();
  }

  /// 设置搜索相似度阈值（0~100）。持久化失败不影响当前会话。
  Future<void> setSearchSimilarity(int value) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberSearchSimilarity(value);
    notifyListeners();
  }

  /// 设置搜索并发线程数（夹到 1~100）。持久化失败不影响当前会话。
  ///
  /// 下一次搜索立即生效（[searchAll] 每次读 [searchThread]）；
  /// 已经在跑的批次不受影响——中途改并发会让「同一轮搜索」的节流语义变得
  /// 不可预测，也会让日志里那一行 concurrency 失去意义。
  Future<void> setSearchThread(int value) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberSearchThread(value);
    notifyListeners();
  }

  /// 加载详情（§8.3）。
  ///
  /// 并发安全性（实测缺陷：详情页「点三次才进得去」、返回后点其他剧仍显示
  /// 上一部剧的信息）：
  /// - 每次调用取一个新的 [_detailRunId]，只有**最新**请求的结果才允许写回状态。
  ///   详情页在 `initState` 的 post-frame 回调里发请求，用户「返回 → 立刻点
  ///   另一部剧」时前一个请求往往还没回来（本机实测 3.9~7.1s），旧响应覆盖
  ///   新响应就会把 A 剧的线路渲染到 B 剧的页面上，点播即串剧；
  /// - 失败写入独立的 [detailError]，不污染浏览页共用的 [lastError]；
  /// - 新请求一律先清掉上一次的详情结果，避免「正在加载」时把上一个条目的
  ///   线路当成当前条目的线路显示出来。
  Future<void> loadDetail(Vod vod) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    final runId = ++_detailRunId;
    _selectedVod = vod;
    _detailResult = null;
    _detailError = null;
    _detailPhase = LoadPhase.loading;
    notifyListeners();
    try {
      // folder 先取 t=<vod_id> 的资源，再逐个取 ids=<分享链> 的分集。
      // 在服务层合并成普通详情后，一次交给标准线路 UI 和 TMDB。
      final outcome = vod.isFolder
          ? await service.folderDetail(
              site,
              vod,
              isCurrent: () => runId == _detailRunId,
            )
          : await service.detail(site, vod.vodId);
      if (runId != _detailRunId) {
        // 已被更新的请求（或已离开详情页）取代：结果直接丢弃，不写回状态。
        log.debug(
          '详情结果已作废 site=${site.key} vod=${vod.vodId} run=$runId',
          scope: 'site',
        );
        return;
      }
      _detailResult = outcome.value;
      _detailPhase = LoadPhase.ready;
      _detailError = outcome.warnings.isEmpty
          ? null
          : AppError(
              AppErrorKind.siteNetwork,
              '${outcome.warnings.length} 条线路加载失败，可刷新详情重试',
              detail: outcome.warnings.map((e) => e.message).join('；'),
              retryable: true,
            );
      for (final warning in outcome.warnings) {
        log.warning(
          '分集加载失败 site=${site.key} ${warning.logLine}',
          scope: 'site',
        );
      }
      final effective = outcome.value.list.firstOrNull ?? vod;
      _selectedVod = effective;
      // TMDB 与标准站点共用完整线路；元数据失败不阻塞选集和播放。
      _tmdbRunId = runId;
      unawaited(
        tmdb.loadForVod(
          effective,
          siteKey: site.key,
          siteName: site.name,
          configId: tmdbConfigId,
          lines: playLinesOf(effective),
        ),
      );
      log.info(
        '详情加载成功 site=${site.key} vod=${vod.vodId} '
        'folder=${vod.isFolder} entries=${outcome.value.list.length} '
        'tmdbVod=${effective.vodId} '
        'lines=${playLinesOf(effective).length} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _detailRunId) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _detailError = failure;
      _detailPhase = LoadPhase.failed;
      log.error(
        '详情加载失败 site=${site.key} vod=${vod.vodId} ${failure.logLine}',
        scope: 'site',
      );
    }
    notifyListeners();
  }

  /// 清空详情错误（详情页「重试」后的提示关闭）。
  void clearDetailError() {
    if (_detailError == null) return;
    _detailError = null;
    notifyListeners();
  }

  List<VodPlayLine> playLinesOf(Vod vod) => parseVodPlayLines(vod);

  /// 解析播放请求（§10.2）。
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return null;
    try {
      final outcome = await service.resolvePlayback(
        site: site,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
      );
      // 退出旧会话并接入本地代理：Header 注入与 Range 都经同一 token 校验（§9.6、§11.3.1）。
      revokeProxySession();
      final decision = await proxyDecision(outcome.value, siteKey: site.key);
      _lastDecision = decision;
      _lastError = null;
      log.info(
        '播放决策 ${decision.logLine} site=${site.key} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'playback',
      );
      notifyListeners();
      return decision;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      log.error(
        '播放决策失败 site=${site.key} ${failure.logLine}',
        scope: 'playback',
      );
      notifyListeners();
      rethrow;
    }
  }

  /// 用详情结果补齐旧历史记录缺失的海报，不改变进度和更新时间。
  void updateHistoryPoster(PlaybackHistory item, String posterUrl) {
    final database = _database;
    final poster = posterUrl.trim();
    if (database == null || poster.isEmpty || item.vodPic == poster) return;
    try {
      database.upsertHistory(
        siteKey: item.siteKey,
        vodId: item.vodId,
        vodName: item.vodName,
        vodPic: poster,
        flag: item.flag,
        episodeName: item.episodeName,
        episodeId: item.episodeId,
        positionMs: item.positionMs,
        durationMs: item.durationMs,
        completed: item.completed,
        updatedAt: item.updatedAt,
      );
      notifyListeners();
    } catch (error) {
      log.warning('补齐历史海报失败：$error', scope: 'history');
    }
  }

  /// 记录播放进度（§15.2）。
  ///
  /// `siteKey` 显式传入而不依赖当前选中站点：命令行播放、历史恢复等场景下
  /// 并不存在“当前站点”，但仍应记录进度。
  void recordProgress({
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
    String? siteKey,
  }) {
    final database = _database;
    final effectiveSiteKey = siteKey ?? _selectedSite?.key ?? 'cli';
    if (database == null) return;
    try {
      database.upsertHistory(
        siteKey: effectiveSiteKey,
        vodId: vod.vodId,
        vodName: vod.vodName,
        vodPic: vod.vodPic,
        flag: flag,
        episodeName: episodeName,
        episodeId: episodeId,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
      );
    } catch (error) {
      log.warning('写入播放进度失败：$error', scope: 'history');
    }
  }

  /// 查询某剧集的历史记录（用于进入播放器时自动续播，§15.2）。
  ///
  /// [episodeName] 可选：同步来的记录 `episode_id` 存的是安卓哈希
  /// （`episodeUrl` 的 SHA-256），用站点入口 URL 查不到，需要集名兜底。
  /// 详见 `AppDatabase.findHistory` 的三级匹配说明。
  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
  }) {
    final database = _database;
    if (database == null) return null;
    try {
      return database.findHistory(
        siteKey: siteKey,
        vodId: vodId,
        flag: flag,
        episodeId: episodeId,
        episodeName: episodeName,
      );
    } catch (error) {
      log.warning('读取播放进度失败:$error', scope: 'history');
      return null;
    }
  }

  /// 「继续播放」位置（§15.2）。
  ///
  /// 已播完或位置过短时返回 null：从零开始比从尾部几秒开始体验更好。
  ///
  /// [episodeName] 参与集消歧（见 [findHistory]）：同步来的记录靠它才能对到集。
  Duration? resumePositionFor({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
  }) {
    final record = findHistory(
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
      episodeName: episodeName,
    );
    if (record == null || record.completed) return null;
    if (record.positionMs < resumeThreshold.inMilliseconds) return null;
    if (record.durationMs > 0 && record.positionMs > record.durationMs - 5000) {
      // 距离结尾不足 5 秒视为已看完。
      return null;
    }
    return Duration(milliseconds: record.positionMs);
  }

  /// 续播位置下限：小于 5 秒不恢复，避免“刚打开就跳”。
  static const Duration resumeThreshold = Duration(seconds: 5);

  // -------------------------------------------------------------------------
  // Phase 5 · 安卓同步的宿主能力（`SyncStateHost`，`design/02` §2）
  // -------------------------------------------------------------------------
  //
  // 这五个成员是“状态层 ↔ 同步层”的唯一接口：同步层不直接改 `AppState`，
  // 而 `app_state.dart` 不 import `sync_state.dart` 的具体实现细节以外的网络层。

  @override
  AppDatabase? get syncDatabase => _database;

  @override
  List<SyncHistoryItem> syncHistoryItems({int limit = 2000}) => [
    for (final row in recentHistory(limit: limit))
      SyncHistoryItem.fromLocal(
        siteKey: row.siteKey,
        vodId: row.vodId,
        vodName: row.vodName,
        vodPic: row.vodPic,
        flag: row.flag,
        episodeName: row.episodeName,
        episodeId: row.episodeId,
        positionMs: row.positionMs,
        durationMs: row.durationMs,
        updatedAt: row.updatedAt,
      ),
  ];

  @override
  List<SyncFavoriteItem> syncFavoriteItems({int limit = 2000}) => [
    for (final row in favorites().take(limit))
      SyncFavoriteItem(
        kind: row.kind,
        siteKey: row.siteKey,
        targetId: row.targetId,
        title: row.title,
        subtitle: row.subtitle,
        updatedAt: row.updatedAt,
      ),
  ];

  /// 保存安卓桥接配置为**新记录**，且 `makeActive: false`
  /// （`design/00` Q10：导入**不**覆盖/切换当前配置）。
  @override
  Future<int?> saveBridgeConfig({
    required String name,
    required String origin,
    required AppConfig config,
    required List<String> diagnostics,
  }) async {
    final database = _database;
    if (database == null) return null;
    try {
      final id = database.saveConfig(
        name: name,
        origin: origin,
        json: config.toJson(),
        contentType: 'android-t4-gateway',
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        makeActive: false,
      );
      database.saveConfigSites(id, config.sites);
      _configs = database.listConfigs();
      _importDiagnosticsSummary = diagnostics.isEmpty
          ? null
          : diagnostics.join('；');
      log.info(
        '安卓桥接配置已存为记录 #$id（未切换当前配置）'
        ' sites=${config.sites.length} origin=${redactUrl(origin)}',
        scope: 'bridge',
      );
      notifyListeners();
      return id;
    } catch (error) {
      log.error('保存安卓桥接配置失败：$error', scope: 'bridge');
      return null;
    }
  }

  /// 与安卓当前配置对齐的配置 JSON（`design/02` §3.5）。
  ///
  /// **保守策略**：只有当当前生效配置的 `origin` 就是某台**已授权**安卓设备的
  /// 地址时（即用户是通过安卓 T4 网关导入的站点）才返回它；否则返回 `null`。
  ///
  /// 为什么保守：`config.url` 为空或不匹配时，安卓会
  /// `if (config.getUrl() == null) return;` **静默忽略**整批记录却仍返回 200；
  /// 而不匹配时还会 `VodConfig.load(config)` **切换安卓当前配置**。
  /// 宁可不发并把原因告诉用户，也不能发一个可能改掉安卓配置的值
  /// （对齐 P3 + P5）。
  @override
  String? syncConfigJson() {
    final record = _activeRecord;
    if (record == null) return null;
    final origin = record.origin.trim();
    if (!origin.startsWith('http://') && !origin.startsWith('https://')) {
      return null;
    }
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return null;
    if (!syncState.isPeerAuthorized(uri.host)) return null;
    return jsonEncode({
      'id': record.id,
      'type': 0,
      'name': record.name,
      'url': origin,
    });
  }

  /// 应用对端推来的设置（白名单子集，`design/02` §3.6；Phase 7 `design/01` §5 扩展）。
  ///
  /// Phase 7 后白名单含 AI 段四个键。其中三个（`tmdb_model` /
  /// `ai_title_extraction` / `ai_ad_detection`）是「安卓有、PC 无」——
  /// 它们不在这里落库，只保留在 `settings.raw` 里供回推（`design/01` §5.2）。
  ///
  /// 凭据类字段若对端未提供，**保留本机原值**——把能用的凭据清空比不同步更糟。
  @override
  Future<void> applySyncedSettings(SyncSettings settings) async {
    if (settings.isEmpty) return;
    var next = tmdbConfig;

    final enabled = settings.values['tmdb_enabled'];
    if (enabled != null) next = next.copyWith(enabled: asFlag(enabled));

    // `tmdb_config` 的值是 **JSON 字符串**（`design/00` §3.1 契约 11），
    // 必须解字符串再映射，不能当对象读。
    final raw = settings.values['tmdb_config'];
    if (raw != null) {
      final decoded = decodeAndroidJsonSetting(raw);
      if (decoded != null) {
        final incoming = TmdbConfig.fromMap(decoded);
        next = incoming.copyWith(
          apiKey: incoming.apiKey.isEmpty ? next.apiKey : incoming.apiKey,
          accessToken: incoming.accessToken.isEmpty
              ? next.accessToken
              : incoming.accessToken,
        );
      }
    }

    await saveTmdbConfig(next);

    // AI 段（Phase 7 新增）。同样先解 JSON 字符串再映射。
    final aiRaw = settings.values['ai_config'];
    if (aiRaw != null) {
      final local = aiConfig;
      final mapped = mapAiConfigFromAndroid(
        aiRaw,
        local: AiConfigLike(
          enabled: local.enabled,
          protocol: local.protocol,
          endpoint: local.endpoint,
          apiKey: local.apiKey,
          model: local.model,
          customUserAgent: local.customUserAgent,
        ),
      );
      if (mapped != null) {
        await saveAiConfig(
          AiConfig(
            enabled: mapped.enabled,
            protocol: mapped.protocol,
            endpoint: mapped.endpoint,
            apiKey: mapped.apiKey,
            model: mapped.model,
            customUserAgent: mapped.customUserAgent,
          ),
        );
      }
    }

    log.info(
      '已应用中端同步设置：keys=${settings.values.keys.join(',')} '
      'unsupported=${settings.unsupportedKeys.join(',')} '
      'sensitive=${settings.sensitiveIncluded}',
      scope: 'sync',
    );
  }

  /// 实时同步已把新记录落库（`design/01` §4.2）：刷新内存历史视图。
  ///
  /// 历史页是每次 build 直接读 `recentHistory()` 的，因此这里只需要
  /// 通知监听者重建；不通知的后果是「库里有了但页面上一直看不到」。
  @override
  void notifySyncedDataChanged() {
    notifyListeners();
  }

  /// 本轮实时轮询要请求的 `siteKey`（`design/01` §6.1）。
  ///
  /// 取舍交给纯逻辑 `selectPollSites`（已有 L1 用例锁定）：
  /// - `pollAllSites` → 返回当前配置的**全部**站点；
  /// - 否则 → 「最近播过的站点」优先，不足时用配置里的站点补齐。
  ///
  /// **为什么不能只返回配置里的前 20 个**：历史记录只会在「最近看过」的
  /// 站点上产生，轮询冷站点等于白发请求；而用户可能配了几百个站点。
  @override
  List<String> syncSiteKeys({required bool all, int limit = 20}) {
    final known = [
      for (final site in _config?.sites ?? const <Site>[]) site.key,
    ];
    final recentlyActive = <String>[];
    for (final row in recentHistory(limit: 200)) {
      if (!recentlyActive.contains(row.siteKey)) {
        recentlyActive.add(row.siteKey);
      }
    }
    final selected = selectPollSites(
      known: known,
      pollAllSites: all,
      recentlyActive: recentlyActive,
      limit: limit,
    );
    // `null` = 轮询全部（`pollAllSites` 的语义由 `selectPollSites` 表达）。
    return selected ?? known;
  }

  List<PlaybackHistory> recentHistory({int limit = 100}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.recentHistory(limit: limit);
    } catch (error) {
      log.warning('读取播放历史失败：$error', scope: 'history');
      return const [];
    }
  }

  List<PlaybackHistory> searchHistory(String keyword) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.searchHistory(keyword);
    } catch (_) {
      return const [];
    }
  }

  void deleteHistory(int id) {
    _database?.deleteHistory(id);
    notifyListeners();
  }

  void clearHistory() {
    _database?.clearHistory();
    // 「清空历史」同时清季度进度，但**保留**匹配与绑定（`03` §6.5）。
    _database?.clearTmdbSeasonProgress();
    log.info('已清空播放历史（配置未受影响）', scope: 'history');
    notifyListeners();
  }

  List<FavoriteEntry> favorites({String? kind}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.listFavorites(kind: kind);
    } catch (_) {
      return const [];
    }
  }

  bool isFavorite({required String kind, required String targetId}) {
    final database = _database;
    final site = _selectedSite;
    if (database == null || site == null) return false;
    try {
      return database.isFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
      );
    } catch (_) {
      return false;
    }
  }

  void toggleFavorite({
    required String kind,
    required String targetId,
    required String title,
    String? subtitle,
  }) {
    final database = _database;
    final site = _selectedSite;
    if (database == null || site == null) return;
    if (isFavorite(kind: kind, targetId: targetId)) {
      database.removeFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
      );
    } else {
      database.upsertFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
        title: title,
        subtitle: subtitle,
      );
    }
    notifyListeners();
  }

  List<SiteHealth> siteHealth() {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.siteHealth();
    } catch (_) {
      return const [];
    }
  }

  /// 清理缓存目录，验证“删除缓存目录后应用可重建”（§16.3）。
  // -------------------------------------------------------------------------
  // Spider 运行时管理（§9.7、§9.8、§17.2）
  // -------------------------------------------------------------------------

  /// 本地 Spider manifest 注册表。
  SpiderManifestRegistry get spiderRegistry => _spiderRegistry;

  /// Spider 宿主监控器。
  SpiderHostSupervisor get spiderSupervisor => _supervisor;

  /// 重新扫描本地 Spider（设置页/管理页调用）。
  Future<List<LocalSpider>> rescanSpiders() async {
    final found = await _spiderRegistry.scan();
    await _supervisor.cleanStaleWorkDirs();
    log.info('本地 Spider 已扫描：${found.length} 个', scope: 'spider');
    notifyListeners();
    return found;
  }

  /// 本地 Spider 列表（供管理页展示）。
  List<LocalSpider> get localSpiders => _spiderRegistry.sortedSpiders;

  /// 运行时状态列表（含崩溃、退避、隔离等级）。
  List<SpiderRuntimeStatus> spiderRuntimeStatuses() => _supervisor.statuses();

  /// 强制停止某站点的 Spider（§18.2「每个站点运行时可随时强制停止」）。
  Future<void> stopSpider(String siteKey) async {
    await _supervisor.stop(siteKey);
    notifyListeners();
  }

  /// 重置站点 Spider 失败计数，允许重新启动（§9.3.1 退避的人工退出）。
  void resetSpider(String siteKey) {
    _supervisor.reset(siteKey);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // 本地代理（§11）
  // -------------------------------------------------------------------------

  bool get proxyRunning => _proxy.isRunning;

  int get proxyPort => _proxy.port;

  String get proxyBaseUrl => _proxy.baseUrl;

  ProxySessionManager get proxySessions => _proxy.sessions;

  /// 当前播放会话的代理 token 指纹（供设置页显示，不回显完整 token）。
  String? get proxySessionFingerprint => _proxySession?.fingerprint;

  /// 启动本地代理（只监听 127.0.0.1）。
  Future<void> startProxy({int port = 0}) async {
    if (_proxy.isRunning) return;
    await _proxy.start(port: port);
    notifyListeners();
  }

  /// 停止本地代理并释放端口（§11.4）。
  Future<void> stopProxy() async {
    _proxySession = null;
    await _proxy.stop();
    notifyListeners();
  }

  /// 为一次播放开启代理会话，并把媒体地址重写为代理 URL（§9.6、§11.3.1）。
  ///
  /// 无需重写的情况直接返回原决策：
  /// - 目标不是 http(s)；
  /// - 决策没有 Header（播放器可直接访问，少一跳开销）；
  /// - 目标被代理策略拒绝（否则会把可直连的地址换成永远 403 的死地址）。
  Future<PlaybackDecision> proxyDecision(
    PlaybackDecision decision, {
    required String siteKey,
  }) async {
    final url = decision.url;
    if (url == null || url.isEmpty) return decision;
    final target = Uri.tryParse(url);
    if (target == null ||
        !(target.isScheme('http') || target.isScheme('https'))) {
      return decision;
    }

    final headers = decision.headers;
    if (headers == null || headers.isEmpty) return decision;

    // 代理只应接管它**确实能代理**的目标：
    // - 策略会拒绝的目标（本机回环、私网、链路本地、云元数据）直接保持直连，
    //   否则会把本来可播放的地址换成永远 403 的地址，造成播放彻底失败；
    // - 会话主机白名单只放行该目标主机，防止被当成任意目标代理。
    final policyDecision = _proxy.policy.evaluateStatic(target);
    if (!policyDecision.allowed) {
      log.info(
        '目标不在代理策略允许范围内，保持直连 '
        'target=${LocalProxyServer.redactProxyTarget(target)} '
        'reason=${policyDecision.reason}',
        scope: 'proxy',
      );
      return decision;
    }

    try {
      if (!_proxy.isRunning) await _proxy.start();
    } catch (error) {
      log.warning('代理启动失败，回退为直连：$error', scope: 'proxy');
      return decision;
    }

    const credentialKeys = {'user-agent', 'referer', 'cookie', 'authorization'};
    final session = _proxy.sessions.create(
      siteKey: siteKey,
      allowedHosts: {target.host},
      userAgent: headers['User-Agent'] ?? headers['user-agent'],
      referer: headers['Referer'] ?? headers['referer'],
      cookie: headers['Cookie'] ?? headers['cookie'],
      authorization: headers['Authorization'] ?? headers['authorization'],
      extraHeaders: {
        for (final entry in headers.entries)
          if (!credentialKeys.contains(entry.key.toLowerCase()))
            entry.key: entry.value,
      },
    );
    _proxySession = session;
    final proxied = _proxy.urlFor(session, target);
    log.info(
      '播放转为本地代理 token=${session.fingerprint} '
      'target=${LocalProxyServer.redactProxyTarget(target)}',
      scope: 'proxy',
    );
    notifyListeners();
    // 走代理后 Header 由代理注入，播放器不再重复携带（避免 Header 泄漏到直连请求）。
    return PlaybackDecision(
      action: decision.action,
      url: proxied,
      headers: HeaderMap(),
      format: decision.format,
      reason: decision.reason,
      flag: decision.flag,
      // 字幕不随代理地址变化：原样透传（§10.3）。
      subs: decision.subs,
      // 弹幕不随代理地址变化：原样透传（§21 Phase 3）。
      danmaku: decision.danmaku,
      // 代理前的原始 Header 留给宿主自己的附加请求（外挂字幕/弹幕）使用。
      upstreamHeaders: decision.headers,
    );
  }

  /// 停止当前播放会话的代理授权（§11.3.1「停止播放即失效」）。
  void revokeProxySession() {
    final session = _proxySession;
    if (session == null) return;
    _proxy.sessions.revoke(session.token);
    _proxySession = null;
  }

  Future<void> resetCache() async {
    try {
      await resetCacheDirectory(paths.cacheDir);
      log.info('缓存目录已重建：${paths.cacheDir}', scope: 'storage');
      _notice = '缓存已清理';
    } catch (error) {
      _lastError = AppError(AppErrorKind.storage, '清理缓存失败', detail: '$error');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _detailRunId++;
    _router.dispose();
    _importService.close();
    _liveService?.close();
    _epgService?.close();
    _tmdbService.close();
    // 联想/热搜的 HTTP 客户端同样要释放。
    _searchSuggestService?.close();
    // §22.2:退出后 sidecar 与代理端口全部释放。
    unawaited(_supervisor.shutdownAll());
    unawaited(_androidPlaybackBridge.close());
    unawaited(_proxy.stop());
    // 猫源 Node 进程树与 bundle 句柄同样必须随退出释放（§9.8）。
    _catPipeline?.close();
    // 同步服务端必须先停：退出后不得继续监听局域网端口（§28.4）。
    // 先摘掉转发监听再 dispose，避免 dispose 过程中的通知回调打到已释放的 AppState。
    syncState.removeListener(notifyListeners);
    syncState.dispose();
    _database?.dispose();
    log.dispose();
    super.dispose();
  }
}
