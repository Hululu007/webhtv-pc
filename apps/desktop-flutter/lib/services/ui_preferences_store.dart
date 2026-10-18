/// UI 偏好持久化（`<configDir>/settings.json` 的 `ui` 段）。
///
/// 为什么单独一段：`settings.json` 已有 `tmdb`（凭据）与 `sync`（同步白名单/设备）
/// 两段，各自有独立的 store。UI 偏好与它们语义无关，混进去会让任何一方保存时
/// 覆盖另一方的键。这里沿用同样的「读改写、只替换自己那一段」模式。
///
/// 当前保存：
/// - `lastSiteKey`：**最近一次使用的站点**；
/// - `videoFitModes`：按 `siteKey + vodId` 记住播放器画面模式；
/// - `themeMode`：**主题模式**（`dark` / `light` / `system`）；
/// - `searchKeywords`：**搜索历史**（去重、最新在前，上限 10；
///   对齐上游安卓「默影视」`Setting.getKeyword/putKeyword` + `RecordAdapter`
///   的 `checkToAdd`：新词提到最前、超出裁剪）；
/// - `searchSimilarity`：**搜索结果相似度阈值**（0~100，上游
///   `Setting.getSearchSimilarity` 默认 30）；
/// - `searchThread`：**搜索并发线程数**（1~100，上游
///   `Setting.getSearchThread` 默认 20、`clampSearchThread` 夹在 1~100）；
/// - `historyClickAction`：**点击历史记录的行为**（`detail` 进详情页 /
///   `play` 直接播放，上游 `HistoryActivity#onItemClick` 是直接播放，
///   PC 端默认改为进详情页，见 `docs/phase6/design/01` §4.1）。
library;

import 'dart:convert';
import 'dart:io';

import '../core/history_view.dart';
import '../core/osd_config.dart';
import '../core/player_buttons.dart';
import 'log_service.dart';
import 'settings_file.dart';

/// 主题模式取值。
///
/// 存字符串而不是 Flutter 的 `ThemeMode`：本层是服务层，不依赖 UI 框架
/// （与 `AppPaths`、`LogService` 同样的分层）。转换放在 `AppState`。
///
/// 默认 `dark`：星等星表以暗色为主身份（夜间、坐在电脑前的使用场景），
/// 亮色是独立设计的「昼间星表」。旧设置文件没有这个键时保持原有行为。
abstract final class UiThemeMode {
  static const String dark = 'dark';
  static const String light = 'light';
  static const String system = 'system';

  static const List<String> values = [dark, light, system];

  /// 把任意输入归一化成合法值；不认识的值回落到默认。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : dark;
  }
}

class UiPreferencesStore {
  UiPreferencesStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;

  // ignore_for_file: prefer_initializing_formals
  final LogService? _log;

  String _lastSiteKey = '';
  final Map<String, String> _videoFitModes = {};

  /// 用户**显式选过**的主题模式；`null` = 从未选过。
  ///
  /// 为什么用可空：`ui` 段是「读改写」的，把默认值固化进文件会让
  /// 「从未选过」和「选过暗色」变得无法区分，也会污染既有设置文件。
  /// 缺省不写盘，语义上「缺席 = 用默认」。
  String? _themeMode;

  /// 搜索历史：去重、最新在前。上限 [_maxSearchKeywords]。
  List<String> _searchKeywords = const [];

  /// 搜索结果相似度阈值（0~100）。`null` = 从未设置过，用默认 [_defaultSimilarity]。
  int? _searchSimilarity;

  /// 搜索并发线程数（1~100）。`null` = 从未设置过，用默认 [_defaultSearchThread]。
  int? _searchThread;

  /// 点击历史记录的行为。`null` = 从未设置过，用默认 [UiHistoryClickAction.detail]。
  String? _historyClickAction;

  /// 屏显开关的**显式**设置；缺席的 id 用 [defaultOsdFlags] 补齐。
  ///
  /// 为什么只存显式项：与 [_themeMode] 同一理由——把默认值固化进文件会让
  /// 「从未设置过」与「设置成默认值」无法区分，也会污染既有设置文件。
  final Map<String, bool> _osdFlags = {};

  /// 按钮顺序的**显式**设置；空表示从未设置过。
  List<String>? _buttonOrder;

  /// 按钮隐藏集的**显式**设置；null 表示从未设置过。
  Set<String>? _buttonHidden;

  bool _loaded = false;

  /// 搜索历史上限（上游安卓 `RecordAdapter.checkToAdd` 同为 10）。
  static const int _maxSearchKeywords = 10;

  /// 相似度默认值：与上游 `Setting.getSearchSimilarity()` 默认 30 一致。
  static const int _defaultSimilarity = 30;

  /// 搜索并发线程数默认值：与上游 `Setting.getSearchThread()` 默认 20 一致。
  static const int _defaultSearchThread = 20;

  /// 并发线程数下限（上游 `clampSearchThread` 为 1~100）。
  static const int _minSearchThread = 1;

  /// 并发线程数上限（上游 `clampSearchThread` 为 1~100）。
  static const int _maxSearchThread = 100;

  /// 最近一次使用的站点 key；从未选过时为空串。
  String get lastSiteKey => _lastSiteKey;

  /// 生效的主题模式：用户选过就用选的，否则用默认（暗色）。
  String get themeMode => _themeMode ?? UiThemeMode.dark;

  /// 用户是否显式选过主题（决定要不要写盘）。
  bool get hasExplicitThemeMode => _themeMode != null;

  /// 搜索历史（去重、最新在前）。
  List<String> get searchKeywords => List.unmodifiable(_searchKeywords);

  /// 生效的相似度阈值：从未设置过时用默认 30（对齐上游安卓）。
  int get searchSimilarity => _searchSimilarity ?? _defaultSimilarity;

  /// 用户是否显式设置过相似度（决定「不限」是不是用户主动选的）。
  bool get hasExplicitSearchSimilarity => _searchSimilarity != null;

  /// 生效的搜索并发线程数：从未设置过时用默认 20（对齐上游安卓）。
  int get searchThread => _searchThread ?? _defaultSearchThread;

  /// 用户是否显式设置过并发线程数。
  bool get hasExplicitSearchThread => _searchThread != null;

  /// 生效的点击历史行为：用户选过就用选的，否则默认进详情页。
  String get historyClickAction =>
      UiHistoryClickAction.normalize(_historyClickAction);

  /// 用户是否显式设置过（决定要不要写盘，与 `themeMode` 同理）。
  bool get hasExplicitHistoryClickAction => _historyClickAction != null;

  /// 生效的屏显开关：显式设置过的项用用户值，其余用默认。
  Map<String, bool> get osdFlags => normalizeOsdFlags(_osdFlags);

  /// 用户是否显式设置过任一屏显开关（决定要不要写盘）。
  bool get hasExplicitOsd => _osdFlags.isNotEmpty;

  /// 生效的按钮顺序：显式设置过就用它（并补全缺失项），否则用默认。
  List<String> get buttonOrder => normalizeButtonOrder(_buttonOrder);

  /// 生效的按钮隐藏集。
  ///
  /// 注意必须传 `List`：Task 2 的 [normalizeButtonHidden] 只认 `List` 与
  /// 逗号分隔 `String`（`_splitIds`），直接喂 `Set` 会静默落成空集。
  Set<String> get buttonHidden => normalizeButtonHidden(_buttonHidden?.toList());

  /// 用户是否显式设置过按钮排版（决定要不要写盘）。
  bool get hasExplicitPlayerButtons =>
      _buttonOrder != null || _buttonHidden != null;

  /// 是否已成功读取过磁盘内容。
  bool get loaded => _loaded;

  String videoFitMode({required String siteKey, required String vodId}) =>
      _videoFitModes[_videoFitKey(siteKey, vodId)] ?? '';

  /// 从磁盘读取。文件不存在或解析失败时保持默认值并记日志（不阻塞启动）。
  Future<void> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final ui = decoded['ui'];
        if (ui is Map) {
          final value = ui['lastSiteKey'];
          if (value is String) _lastSiteKey = value.trim();
          // 只接受合法值；文件里被手改成别的字符串时回落到默认，不写坏状态。
          final mode = ui['themeMode'];
          if (mode is String &&
              UiThemeMode.values.contains(mode.trim().toLowerCase())) {
            _themeMode = mode.trim().toLowerCase();
          }
          final modes = ui['videoFitModes'];
          if (modes is Map) {
            for (final entry in modes.entries) {
              if (entry.key is String && entry.value is String) {
                _videoFitModes[entry.key as String] = entry.value as String;
              }
            }
          }
          final keywords = ui['searchKeywords'];
          if (keywords is List) {
            final restored = <String>[
              for (final item in keywords)
                if (item is String && item.trim().isNotEmpty) item.trim(),
            ];
            // 恢复时同样去重裁剪，防止手改文件塞进超长列表。
            _searchKeywords = _dedupeKeywords(restored);
          }
          final similarity = ui['searchSimilarity'];
          if (similarity is int && similarity >= 0 && similarity <= 100) {
            _searchSimilarity = similarity;
          } else if (similarity is num &&
              similarity.toInt() >= 0 &&
              similarity.toInt() <= 100) {
            // 手改文件写成 30.0 这类浮点时也接受。
            _searchSimilarity = similarity.toInt();
          }
          final thread = ui['searchThread'];
          if (thread is num) {
            // 手改文件写坏的值（0、-5、999）一律夹到合法区间，
            // 与上游 `putSearchThread` 的 `clampSearchThread` 同语义：
            // 并发度 0 会让搜索一个站点都不发。
            _searchThread = _clampSearchThread(thread.toInt());
          }
          final clickAction = ui['historyClickAction'];
          if (clickAction is String) {
            // 只接受合法值；手改成别的字符串时回落到默认，不写坏状态。
            if (UiHistoryClickAction.values.contains(
              clickAction.trim().toLowerCase(),
            )) {
              _historyClickAction = clickAction.trim().toLowerCase();
            }
          }
          // 屏显开关：只接受 bool；非法值忽略（该项回落默认）。
          final osd = ui['osd'];
          if (osd is Map) {
            for (final id in OsdFlag.values) {
              final value = osd[id];
              if (value is bool) _osdFlags[id] = value;
            }
          }
          // 按钮排版：顺序与隐藏集各自独立；格式兼容 List 与逗号分隔字符串。
          final buttons = ui['playerButtons'];
          if (buttons is Map) {
            final order = buttons['order'];
            if (order != null) {
              final parsed = normalizeButtonOrder(order);
              // 只有真的解析出内容才视为「显式设置过」，
              // 否则一个空数组会把「从未设置」误判成「设置成默认」。
              if (_hasAnyKnownId(order)) _buttonOrder = parsed;
            }
            final hidden = buttons['hidden'];
            if (hidden != null && _hasAnyKnownId(hidden)) {
              _buttonHidden = normalizeButtonHidden(hidden);
            }
          }
        }
      }
      _loaded = true;
    } catch (error) {
      _log?.warning('读取 UI 偏好失败，使用默认值：$error', scope: 'ui');
      _lastSiteKey = '';
      _loaded = true;
    }
  }

  /// 记住最近使用的站点。key 为空时视为「清除记录」。
  ///
  /// 写入失败**不影响**当前会话（内存里已生效），只记日志。
  Future<bool> rememberSite(String key) async {
    final normalized = key.trim();
    if (normalized == _lastSiteKey) return true;
    _lastSiteKey = normalized;
    return _persist();
  }

  Future<bool> rememberVideoFitMode({
    required String siteKey,
    required String vodId,
    required String mode,
  }) async {
    final key = _videoFitKey(siteKey, vodId);
    if (_videoFitModes[key] == mode) return true;
    _videoFitModes[key] = mode;
    // 偏好是缓存，不允许无限增长。
    if (_videoFitModes.length > 200) {
      _videoFitModes.remove(_videoFitModes.keys.first);
    }
    return _persist();
  }

  /// 记住主题模式。非法值归一化为默认。
  ///
  /// 与 `rememberVideoFitMode` 一样，写盘失败**不影响**当前会话（内存里已生效），
  /// 只记日志。
  Future<bool> rememberThemeMode(String mode) async {
    final normalized = UiThemeMode.normalize(mode);
    if (normalized == _themeMode) return true;
    _themeMode = normalized;
    return _persist();
  }

  /// 记住一次搜索关键词：提到最前、去重、裁剪到上限 10
  /// （上游安卓 `RecordAdapter.add` 同语义）。空词忽略。
  Future<bool> rememberSearchKeyword(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) return Future.value(true);
    final next = _dedupeKeywords([
      text,
      ..._searchKeywords.where((item) => item != text),
    ]);
    if (_listEquals(next, _searchKeywords)) return Future.value(true);
    _searchKeywords = next;
    return _persist();
  }

  /// 删除单条搜索历史（长按/删除按钮，上游 `RecordAdapter` 长按删除）。
  Future<bool> removeSearchKeyword(String keyword) {
    final next = [
      for (final item in _searchKeywords)
        if (item != keyword) item,
    ];
    if (next.length == _searchKeywords.length) return Future.value(true);
    _searchKeywords = next;
    return _persist();
  }

  /// 清空搜索历史。
  Future<bool> clearSearchKeywords() {
    if (_searchKeywords.isEmpty) return Future.value(true);
    _searchKeywords = const [];
    return _persist();
  }

  /// 记住相似度阈值（0~100，超范围归一到默认）。
  Future<bool> rememberSearchSimilarity(int value) {
    final normalized = value < 0
        ? _defaultSimilarity
        : (value > 100 ? 100 : value);
    if (_searchSimilarity == normalized) return Future.value(true);
    _searchSimilarity = normalized;
    return _persist();
  }

  /// 记住搜索并发线程数（夹到 1~100，上游 `clampSearchThread`）。
  Future<bool> rememberSearchThread(int value) {
    final normalized = _clampSearchThread(value);
    if (_searchThread == normalized) return Future.value(true);
    _searchThread = normalized;
    return _persist();
  }

  /// 记住点击历史记录的行为。非法值归一化为默认。
  Future<bool> rememberHistoryClickAction(String mode) {
    final normalized = UiHistoryClickAction.normalize(mode);
    if (normalized == _historyClickAction) return Future.value(true);
    _historyClickAction = normalized;
    return _persist();
  }

  /// 记住单项屏显开关。非法 id 忽略（不写坏状态）。
  Future<bool> rememberOsdFlag(String id, bool enabled) {
    if (!OsdFlag.values.contains(id)) return Future.value(true);
    if (_osdFlags[id] == enabled) return Future.value(true);
    _osdFlags[id] = enabled;
    return _persist();
  }

  /// 记住按钮顺序。输入的非法 id 会被过滤、缺失项会在读取时补全。
  Future<bool> rememberButtonOrder(List<String> order) {
    final normalized = normalizeButtonOrder(order);
    if (_listEquals(normalized, _buttonOrder ?? const [])) {
      return Future.value(true);
    }
    _buttonOrder = normalized;
    return _persist();
  }

  /// 记住按钮隐藏集。非法 id 会被过滤。
  Future<bool> rememberButtonHidden(Set<String> hidden) {
    final normalized = normalizeButtonHidden(hidden.toList());
    if (_setEquals(normalized, _buttonHidden ?? const <String>{})) {
      return Future.value(true);
    }
    _buttonHidden = normalized;
    return _persist();
  }

  /// 恢复按钮排版默认：清除两个键（对齐上游 `PlayerButtonSetting.reset()`，
  /// `PlayerButtonSetting.java:140-144`）。
  ///
  /// 上游还会清 `HIDDEN_SEEDED`；PC 端没有播种机制（无默认隐藏项），
  /// 所以只清两个键。详见 `docs/phase8/design/03` §4.5。
  Future<bool> resetPlayerButtons() {
    if (_buttonOrder == null && _buttonHidden == null) {
      return Future.value(true);
    }
    _buttonOrder = null;
    _buttonHidden = null;
    return _persist();
  }

  /// 夹到 1~100：0 或负数会让搜索一个请求都不发，超大值会打满对端。
  static int _clampSearchThread(int value) {
    if (value < _minSearchThread) return _minSearchThread;
    if (value > _maxSearchThread) return _maxSearchThread;
    return value;
  }

  /// 去重 + 裁剪到上限（保持传入顺序）。
  List<String> _dedupeKeywords(List<String> items) {
    final seen = <String>[];
    for (final item in items) {
      if (item.isEmpty || seen.contains(item)) continue;
      seen.add(item);
      if (seen.length >= _maxSearchKeywords) break;
    }
    return seen;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  /// 输入里是否至少有一个合法的按钮 id。
  ///
  /// 用于区分「显式存过（哪怕是空集）」与「文件里有个空壳对象」。
  /// 空数组/空串一律视为未设置，避免把默认值固化进文件。
  bool _hasAnyKnownId(Object? raw) {
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is String) ids.add(item.trim());
      }
    } else if (raw is String) {
      for (final part in raw.split(',')) {
        ids.add(part.trim());
      }
    }
    return ids.any(
      (id) => id.isNotEmpty && kPlayerButtons.any((spec) => spec.id == id),
    );
  }

  String _videoFitKey(String siteKey, String vodId) =>
      '${siteKey.trim()}\\n${vodId.trim()}';

  /// 写盘队列尾：串行化所有 `_persist` 调用。
  ///
  /// 为什么必须串行：`_persist` 是「写 tmp → 删旧 → 改名」三步，并发时两个
  /// 调用会在**同一个** `.tmp` 上互相踩（A 刚删掉 tmp，B 的 rename 就撞空
  /// 抛异常），最终 settings.json 可能被整个弄丢——实测连续搜索的 unawaited
  /// 历史落盘就触发了这个竞态（Windows 上 delete/rename 原子性比 POSIX 差）。
  /// 生产影响不止测试：任何连续两次偏好写入都可能丢掉全部 UI 设置。
  Future<void> _persistQueue = Future<void>.value();

  /// 串行化后的 `_persist`：本次写入在上一次完成后才开始。
  Future<bool> _persist() {
    final result = _persistQueue.then((_) => _doPersist());
    // 队列推进不能被单次失败阻塞：吞掉错误后继续接受下一次写盘。
    _persistQueue = result.then<void>(
      (_) {},
      onError: (_) {},
    );
    return result;
  }

  Future<bool> _doPersist() async {
    // 写盘经共享工具（`settings_file.dart`）：
    // - **同步临界区**：`SyncState` 同时也在写同一个 `settings.json`。
    //   Dart 单线程，所以「读→改→写 tmp→rename」之间只要没有 `await`
    //   就不可能交错——这同时堵住了「文件丢失」与更隐蔽的「丢更新」
    //   （对方刚写的段被自己的陈旧读覆盖回去）。
    // - **独占临时名**：两者原先共用 `$path.tmp`，会互相覆盖。
    // - **只改 `ui` 段**：读回时保留 `sync` 段。
    final result = writeSettingsSectionSync(
      path: path,
      writer: SettingsWriter.uiPreferences,
      mutate: (root) {
        final ui = <String, Object?>{'lastSiteKey': _lastSiteKey};
        if (_videoFitModes.isNotEmpty) ui['videoFitModes'] = _videoFitModes;
        // 只有用户显式选过才写：缺席 = 默认，避免把默认值固化进文件。
        final mode = _themeMode;
        if (mode != null) ui['themeMode'] = mode;
        if (_searchKeywords.isNotEmpty) ui['searchKeywords'] = _searchKeywords;
        // 相似度同上：只有显式设置过才写，缺席 = 默认 30。
        final similarity = _searchSimilarity;
        if (similarity != null) ui['searchSimilarity'] = similarity;
        // 并发线程数：同样缺席 = 默认 20。
        final thread = _searchThread;
        if (thread != null) ui['searchThread'] = thread;
        // 点击行为同上：只有显式设置过才写，缺席 = 默认 detail。
        final clickAction = _historyClickAction;
        if (clickAction != null) ui['historyClickAction'] = clickAction;
        // 屏显：只有显式设置过的项才写（缺席 = 默认）。
        if (_osdFlags.isNotEmpty) ui['osd'] = _osdFlags;
        // 按钮排版：两个键各自独立；都缺席时整个 playerButtons 不写。
        final order = _buttonOrder;
        final hidden = _buttonHidden;
        if (order != null || hidden != null) {
          ui['playerButtons'] = <String, Object?>{
            if (order != null) 'order': order,
            if (hidden != null) 'hidden': hidden.toList()..sort(),
          };
        }
        root['ui'] = ui;
        return true;
      },
    );
    if (!result.ok) {
      _log?.error('保存 UI 偏好失败：${result.error}', scope: 'ui');
      return false;
    }
    return true;
  }
}
