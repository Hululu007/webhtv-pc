/// 站点排序偏好（`docs/phase9/README.md` P1-3）。
///
/// 目前只包含「按健康度排序搜索结果」：
/// - 关闭（默认）= 保持配置顺序，与 Phase 2–8 完全一致；
/// - 开启 = 按实测成功率降序，**没有样本的站点排在最后**（不是 0%，也不是最前）。
///
/// 不做「手动排序/屏蔽」的隐藏配置：没有 UI 入口的开关等于假功能，
/// 等有界面时再加字段。
library;

class SiteOrderSettings {
  const SiteOrderSettings({this.healthSort = false});

  const SiteOrderSettings.defaults() : this();

  /// 搜索/换源是否优先使用健康的站点。
  final bool healthSort;

  SiteOrderSettings copyWith({bool? healthSort}) =>
      SiteOrderSettings(healthSort: healthSort ?? this.healthSort);

  Map<String, Object?> toJson() => <String, Object?>{'healthSort': healthSort};

  factory SiteOrderSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return SiteOrderSettings(
      healthSort: map['healthSort'] is bool
          ? map['healthSort'] as bool
          : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SiteOrderSettings && other.healthSort == healthSort;

  @override
  int get hashCode => healthSort.hashCode;

  @override
  String toString() => 'SiteOrderSettings(healthSort=$healthSort)';
}

/// 按健康度重排站点 key；[scores] 缺失表示该站点没有样本。
///
/// 稳定性：分数相同（或都没有样本）时保持传入顺序；不返回缺失的 key。
List<String> orderSiteKeysByHealth({
  required List<String> keys,
  required bool enabled,
  required Map<String, double> scores,
}) {
  if (!enabled || keys.length <= 1) return List<String>.of(keys);
  final indexed = keys.indexed.toList();
  indexed.sort((a, b) {
    final scoreA = scores[a.$2];
    final scoreB = scores[b.$2];
    if (scoreA == null && scoreB == null) return a.$1.compareTo(b.$1);
    if (scoreA == null) return 1;
    if (scoreB == null) return -1;
    final byScore = scoreB.compareTo(scoreA);
    return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
