/// 播放器轨道（音轨/视频轨）的视图模型（`docs/phase9/design/01` §2）。
///
/// 为什么不直接暴露 media-kit 的 `AudioTrack`/`VideoTrack`：
/// - 播放器页只该依赖稳定字段（id/label/语言），不该知道 media-kit 的版本细节；
/// - id 必须原样保留——**不能用列表下标**，轨道顺序会随容器变化；
/// - 单测可以在不创建 `Player` 的情况下穷举「0 条 / 1 条 / 多条 / auto / no」。
library;

/// 轨道种类。
enum PlayerTrackKind {
  audio('audio', '音轨'),
  video('video', '视频轨');

  const PlayerTrackKind(this.id, this.label);

  /// 落盘/日志标识，**不得改名**。
  final String id;

  /// UI 中文名。
  final String label;
}

/// 引擎上报的一条轨道（中性结构）。
class PlayerTrackInfo {
  const PlayerTrackInfo({
    required this.id,
    this.title = '',
    this.language = '',
    this.isDefault = false,
  });

  /// 引擎轨道 id（如 `1`、`auto`、`no`）。**不得用下标替代**。
  final String id;

  /// 引擎给的标题（可能为空）。
  final String title;

  /// 语言标记（可能为空）。
  final String language;

  /// 是否带 default 标记。
  final bool isDefault;
}

/// 菜单里的一行。
class PlayerTrackOption {
  const PlayerTrackOption({
    required this.kind,
    required this.id,
    required this.label,
    this.language = '',
    this.isAuto = false,
    this.isOff = false,
    this.isDefault = false,
    this.selected = false,
  });

  final PlayerTrackKind kind;
  final String id;
  final String label;
  final String language;

  /// 「自动」项。
  final bool isAuto;

  /// 「关闭」项（仅字幕语义；音轨/视频轨不会出现）。
  final bool isOff;

  /// 引擎声明的默认轨。
  final bool isDefault;

  /// 当前是否选中。
  final bool selected;

  /// 是否可以点击切换。`auto` 可点（回到自动），`no` 不出现。
  bool get selectable => !isOff;

  PlayerTrackOption copyWith({bool? selected}) => PlayerTrackOption(
    kind: kind,
    id: id,
    label: label,
    language: language,
    isAuto: isAuto,
    isOff: isOff,
    isDefault: isDefault,
    selected: selected ?? this.selected,
  );

  @override
  bool operator ==(Object other) =>
      other is PlayerTrackOption &&
      other.kind == kind &&
      other.id == id &&
      other.label == label &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(kind, id, label, selected);

  @override
  String toString() => 'PlayerTrackOption(${kind.id}:$id, "$label", '
      'auto=$isAuto selected=$selected)';
}

/// 构造菜单项。
///
/// 规则：
/// 1. 过滤 `no`（关闭）——音轨/视频轨没有「关闭」语义，出现会误导；
/// 2. `auto` 保留为「自动」，排在第一位；
/// 3. 其余按引擎顺序，label 取 `title`，缺失时用「音轨 N / 视频轨 N」；
/// 4. 语言非空时附在 label 末尾（`· 国语`），不去重、不翻译；
/// 5. 当前选中项：id 精确匹配；selectedId 为空或 `auto` 时选中「自动」。
List<PlayerTrackOption> buildPlayerTrackOptions({
  required PlayerTrackKind kind,
  required Iterable<PlayerTrackInfo> tracks,
  String? selectedId,
}) {
  final normalizedSelected = (selectedId ?? '').trim();
  final options = <PlayerTrackOption>[];
  var ordinal = 0;

  for (final track in tracks) {
    final id = track.id.trim();
    if (id.isEmpty || id == 'no') continue;
    final isAuto = id == 'auto';
    if (!isAuto) ordinal += 1;

    final title = track.title.trim();
    final fallback = '${kind.label} $ordinal';
    final base = isAuto ? '自动' : (title.isEmpty ? fallback : title);
    final language = track.language.trim();
    final label = language.isEmpty || isAuto ? base : '$base · $language';

    final selected = isAuto
        ? (normalizedSelected.isEmpty || normalizedSelected == 'auto')
        : normalizedSelected == id;

    options.add(
      PlayerTrackOption(
        kind: kind,
        id: id,
        label: label,
        language: language,
        isAuto: isAuto,
        isDefault: track.isDefault,
        selected: selected,
      ),
    );
  }

  return options;
}

/// 当前选中的项；找不到时返回 null（不猜第一个）。
PlayerTrackOption? selectedPlayerTrack(List<PlayerTrackOption> options) {
  for (final option in options) {
    if (option.selected) return option;
  }
  return null;
}

/// 是否值得给用户显示「轨道」入口。
///
/// 「自动」不算一条可切换的轨道：`auto + 1 条真实轨` 时切换没有意义
/// （auto 只是回到引擎默认，不会产生不同音轨）。至少 2 条真实轨道才显示。
bool hasSwitchableTracks(List<PlayerTrackOption> options) {
  final real = options.where((option) => !option.isAuto && !option.isOff);
  return real.length >= 2;
}
