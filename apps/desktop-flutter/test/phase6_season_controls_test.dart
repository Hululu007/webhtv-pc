/// 季度按钮常驻（`docs/phase6/design/03` §2）。
///
/// `TmdbState` 的构造方式与 `test/phase4_tmdb_ui_test.dart` 完全一致：
/// **直接构造**（`TmdbState(config:, service:, identityService:,
/// seasonService:, enrichmentService:)`），不走 `AppState`——
/// `TmdbState` 是独立可测的组件，`AppState` 里的那个实例需要 bootstrap
/// 才能装配，测起来更慢也更脆。
///
/// `InMemoryTmdbMatchStore` 在 `tmdb_identity_service.dart`，
/// `InMemoryTmdbSeasonStore` 与 `TmdbSourceLine` 在 `tmdb_season_service.dart`
/// ——**都不在 `tmdb_stores.dart`**（该文件是数据库版 store 的实现）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

/// 假 HTTP 客户端：按路径后缀返回预置 JSON（与 `phase4_tmdb_ui_test` 同构）。
class _FakeClient extends http.BaseClient {
  _FakeClient(this._routes);

  /// 路径后缀 → 响应体。
  final Map<String, Object?> _routes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final entry in _routes.entries) {
      if (request.url.path.endsWith(entry.key)) {
        final body = entry.value;
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          200,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _tmdbState({
  required TmdbConfig Function() config,
  required http.Client client,
}) {
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

// `Vod` 的构造**不是** `const`（`core/protocol.dart:818`），
// 因此这里不能写 `const Vod(...)`。
Vod _vod() => Vod(vodId: 'v1', vodName: '剧名');

/// `TmdbState.beginLoad` 收的是 `TmdbSourceLine`（不是 `VodPlayLine`）。
TmdbSourceLine _line({required int count}) => TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: List.generate(count, (i) => '第${i + 1}集'),
);

void main() {
  /// 走完整的匹配 + 详情流程，得到可渲染的 `TmdbState`。
  Future<TmdbState> matchedState({
    required int episodeCount,
    required List<int> tmdbSeasons,
    required Map<int, int> seasonCounts,
    String mediaType = 'tv',
  }) async {
    final tmdbId = mediaType == 'tv' ? 1399 : 550;
    final client = _FakeClient({
      '/search/multi': {
        'results': [
          {
            'id': tmdbId,
            'media_type': mediaType,
            if (mediaType == 'tv') 'name': '剧名' else 'title': '剧名',
            if (mediaType == 'tv')
              'first_air_date': '2024-01-01'
            else
              'release_date': '2024-01-01',
          },
        ],
      },
      '/tv/$tmdbId': {
        'id': tmdbId,
        'name': '剧名',
        'seasons': [
          for (final season in tmdbSeasons)
            {
              'season_number': season,
              'episode_count': seasonCounts[season] ?? 0,
            },
        ],
      },
      '/movie/$tmdbId': {'id': tmdbId, 'title': '剧名'},
    });
    final state = _tmdbState(config: _ready, client: client);
    final generation = state.beginLoad(
      siteKey: 's',
      vodId: 'v1',
      sourceTitle: '剧名',
      vod: _vod(),
      line: _line(count: episodeCount),
    );
    await state.loadMatch(generation: generation, sourceTitle: '剧名');
    await state.loadDetail(
      generation: generation,
      tmdbSeasons: tmdbSeasons,
      seasonCounts: seasonCounts,
    );
    return state;
  }

  Future<void> pumpSelector(
    WidgetTester tester,
    TmdbState tmdb, {
    VoidCallback? onSelectManual,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 16),
    bool showManualEntry = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TmdbSeasonSelector(
            state: tmdb,
            onSelectManual: onSelectManual,
            padding: padding,
            showManualEntry: showManualEntry,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('季度按钮常驻（design/03 §2）', () {
    testWidgets('多季：按钮 + chip 条并存', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-2')), findsOneWidget);
      tmdb.dispose();
    });

    testWidgets('单季：按钮仍常驻（这是改绑的唯一入口）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-context')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsNothing);
      tmdb.dispose();
    });

    testWidgets('未确定季度：按钮文案是「选择季度」', (tester) async {
      // 7 集，而 S1=3、S2=2：既不能切片（3+2≠7），单季兼容也不成立
      // （S1 的 3 集 < 7），因此 availableSeasons 为空。
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.text('选择季度'), findsWidgets);
      tmdb.dispose();
    });

    testWidgets('点季度按钮触发 onSelectManual', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      var opened = 0;
      await pumpSelector(tester, tmdb, onSelectManual: () => opened++);

      await tester.tap(find.byKey(const ValueKey('tmdb-season-button')));
      await tester.pump();
      expect(opened, 1);
      tmdb.dispose();
    });

    // `design/03` C4：电影不渲染季度按钮。
    testWidgets('电影 → 季度按钮不渲染', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [],
        seasonCounts: const {},
        mediaType: 'movie',
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
      tmdb.dispose();
    });

    // `design/03` C5：未匹配 TMDB → 不渲染。
    testWidgets('未匹配 → 季度按钮不渲染', (tester) async {
      final client = _FakeClient({
        '/search/multi': {'results': []},
      });
      final tmdb = _tmdbState(config: _ready, client: client);
      final generation = tmdb.beginLoad(
        siteKey: 's',
        vodId: 'v1',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 3),
      );
      await tmdb.loadMatch(generation: generation, sourceTitle: '剧名');
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
      tmdb.dispose();
    });

    // `design/03` §2.3：按钮必须与既有 key **并存**（不替换、不改名）。
    testWidgets('未确定季度时 tmdb-choose-season 与按钮并存', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsOneWidget);
      tmdb.dispose();
    });

    // 季度选择器**不得**因加按钮而改变行高（Global Constraints：
    // 任何净高度变化会把控件挤出测试视口）。
    testWidgets('加按钮后行高仍是 tmdbSeasonSelectorHeight', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(tester, tmdb);

      final box = tester.getSize(
        find.byKey(const ValueKey('tmdb-season-button')).first,
      );
      expect(
        box.height,
        lessThanOrEqualTo(tmdbSeasonSelectorHeight),
        reason: '按钮必须在既有行高内，不得把这一行撑高',
      );
      tmdb.dispose();
    });

    testWidgets('showManualEntry=false 时按钮禁用（不给假入口）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      // **必须传一个非 null 的回调**：否则 `onPressed` 本来就是 null，
      // 断言在「有守卫」与「没守卫」两种实现下都绿——测不出守卫是否存在
      // （变异自检抓到的缺口）。
      var opened = 0;
      await pumpSelector(
        tester,
        tmdb,
        showManualEntry: false,
        onSelectManual: () => opened++,
      );

      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('tmdb-season-button')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'showManualEntry=false 时即使传了回调也不得可点',
      );

      // 点一下也不应该触发（禁用态真的不透传）。
      await tester.tap(
        find.byKey(const ValueKey('tmdb-season-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(opened, 0);
      tmdb.dispose();
    });

    testWidgets('showManualEntry=true 时回调真的接通', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      var opened = 0;
      await pumpSelector(tester, tmdb, onSelectManual: () => opened++);

      await tester.tap(find.byKey(const ValueKey('tmdb-season-button')));
      await tester.pump();
      expect(opened, 1, reason: '默认（true）必须可点');
      tmdb.dispose();
    });

    testWidgets('padding 参数真的生效（纯 TMDB 页要贴合自己的内容列）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(
        tester,
        tmdb,
        padding: const EdgeInsets.symmetric(horizontal: 2),
      );

      final left = tester.getTopLeft(
        find.byKey(const ValueKey('tmdb-season-button')).first,
      );
      expect(
        left.dx,
        lessThan(10),
        reason: 'padding.left=2 时按钮应贴近左沿；写死 16 会让它偏移到 ~16',
      );
      tmdb.dispose();
    });
  });

  group('tmdbSeasonButtonLabel（纯函数）', () {
    test('有选中季 → 第 N 季', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      expect(tmdbSeasonButtonLabel(tmdb), '第 1 季');
      tmdb.dispose();
    });

    test('特别篇 → 特别篇', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [0],
        seasonCounts: const {0: 3},
      );
      expect(tmdbSeasonButtonLabel(tmdb), '特别篇');
      tmdb.dispose();
    });

    // `design/03` C3：解析不出季度 → 「选择季度」。
    test('无法解析季度 → 选择季度', () async {
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(tmdb.selectedSeason, lessThan(0), reason: '前置：确实没解析出季度');
      expect(tmdbSeasonButtonLabel(tmdb), '选择季度');
      tmdb.dispose();
    });

    // `design/03` §2.2 的中间一行：`selectedSeason < 0` 但**解析出了季度**。
    // 当前 `TmdbState` 在 `_availableSeasons` 非空时总会把 `_selectedSeason`
    // 落定（`tmdb_state.dart` 的 `scope is KnownSeason` / `_defaultSeasonOf`），
    // 因此这一行现在**不可达**。本用例把它锁成「不可达」这个事实，
    // 若将来状态机改了、`selectedSeason` 可能为 -1 而季度已解析，
    // 这条会失败并提醒实现补上 §2.2 的中间行。
    test('selectedSeason<0 而季度已解析 → 不可达（现状）', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(tmdb.availableSeasons, isNotEmpty, reason: '前置：解析出了季度');
      expect(
        tmdb.selectedSeason,
        greaterThanOrEqualTo(0),
        reason:
            'availableSeasons 非空时 TmdbState 总会落定 selectedSeason，'
            '因此 §2.2 的「有季度但 selectedSeason<0」这一行当前不可达。'
            '若这条失败，说明状态机变了，需要补 §2.2 的中间行文案逻辑。',
      );
      tmdb.dispose();
    });
  });
}
