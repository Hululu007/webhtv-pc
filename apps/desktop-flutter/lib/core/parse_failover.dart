/// 解析接口失败切换（`docs/phase9/README.md` P1-4）。
///
/// 只做「当前接口失败后按配置顺序尝试其他 JSON 类接口」：
/// - 默认关闭，行为与 Phase 3–8 完全一致；
/// - 不做用户自定义排序：没有排序 UI 的配置等于假功能，等有界面再加；
/// - 只尝试 `type=1/2/3` 且声明了 `url` 的接口，跳过 Web 嗅探/Super（PC 不支持）。
library;

import 'parse_runtime.dart';
import 'protocol.dart';

class ParseFailoverSettings {
  const ParseFailoverSettings({this.enabled = false, this.maxAttempts = 2});

  const ParseFailoverSettings.defaults() : this();

  /// 是否允许失败后尝试其他接口。
  final bool enabled;

  /// 单次播放最多尝试几个接口（含首选）；至少 1。
  final int maxAttempts;

  ParseFailoverSettings normalized() =>
      ParseFailoverSettings(enabled: enabled, maxAttempts: _clamp(maxAttempts));

  ParseFailoverSettings copyWith({bool? enabled, int? maxAttempts}) =>
      ParseFailoverSettings(
        enabled: enabled ?? this.enabled,
        maxAttempts: _clamp(maxAttempts ?? this.maxAttempts),
      );

  static int _clamp(int value) => value < 1
      ? 1
      : (value > 5 ? 5 : value);

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'maxAttempts': maxAttempts,
  };

  factory ParseFailoverSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final attempts = map['maxAttempts'];
    return ParseFailoverSettings(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      maxAttempts: attempts is num ? _clamp(attempts.toInt()) : 2,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ParseFailoverSettings &&
      other.enabled == enabled &&
      other.maxAttempts == maxAttempts;

  @override
  int get hashCode => Object.hash(enabled, maxAttempts);

  @override
  String toString() =>
      'ParseFailoverSettings(enabled=$enabled, maxAttempts=$maxAttempts)';
}

/// 构造失败切换的候选列表（不含首选），保持配置顺序。
///
/// 规则：
/// - `enabled == false` 或 `maxAttempts <= 1` → 空表；
/// - 只收 `type=1/2/3` 且 `url` 非空的接口；
/// - 按 `name + url` 去重，避免同一条目被重复尝试；
/// - 总数不超过 `maxAttempts - 1`。
List<ParseSelection> parseFailoverSelections({
  required ParseSelection primary,
  required List<ParseEntry> entries,
  required ParseFailoverSettings settings,
}) {
  if (!settings.enabled || settings.maxAttempts <= 1) return const [];
  final normalized = settings.normalized();
  final primaryKey = _key(primary.entry);
  final seen = <String>{primaryKey};
  final result = <ParseSelection>[];
  for (final entry in entries) {
    if (result.length >= normalized.maxAttempts - 1) break;
    final url = entry.url?.trim() ?? '';
    if (url.isEmpty) continue;
    final kind = parseKindOf(entry.type);
    if (!parseKindSupported(kind)) continue;
    final key = _key(entry);
    if (!seen.add(key)) continue;
    result.add(
      ParseSelection(entry: entry, kind: kind),
    );
  }
  return result;
}

String _key(ParseEntry entry) => '${entry.name}\u0000${entry.url ?? ''}';
