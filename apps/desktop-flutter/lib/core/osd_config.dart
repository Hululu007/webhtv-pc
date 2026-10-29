/// 屏显（OSD）开关模型（`docs/phase8/design/02` §5）。
///
/// 纯数据 + 纯函数：不依赖 Flutter，不碰磁盘，便于单元测试直接覆盖
/// 「默认值」「归一化」「全关判定」三件事。
///
/// 上游依据：`PlayerSetting.java:562-563` 的 7 项 `getDisplayChecked()`，
/// 默认值见 `PlayerSetting.java:508-560`。
library;

/// 屏显开关的稳定 id。
///
/// 这些字符串会落盘（`settings.json` 的 `ui.osd`），**不得改名**。
abstract final class OsdFlag {
  /// 上左：标题（片名 · 第 N 集）。
  static const String title = 'title';

  /// 上左第二行：分辨率。
  static const String size = 'size';

  /// 上右：时钟。
  ///
  /// **与上游的有意差异**：上游 `display_time` 默认 false，PC 端默认 true。
  /// 理由：PC 是「坐在电脑前」的场景（`PRODUCT.md` §Users），全屏播放时
  /// 任务栏不可见，时钟是真实需求（用户 2026-10-18 确认）。
  static const String time = 'time';

  /// 下左：播放进度。
  static const String progress = 'progress';

  /// 下右：网速。
  ///
  /// **本轮无实现**（`docs/phase8/design/02` §3.6）：PC 端 `PlayerController`
  /// 没有字节级吞吐量，只覆盖本地代理流量会误导用户。
  /// 开关保留但置灰，副标题写明「本版本未采集网速」。
  static const String traffic = 'traffic';

  /// 底部 2dp 迷你进度条。
  static const String mini = 'mini';

  /// 顶部诊断面板。
  static const String diagnostics = 'diagnostics';

  /// 全部 id，顺序即配置页的展示顺序。
  static const List<String> values = [
    title,
    size,
    time,
    progress,
    traffic,
    mini,
    diagnostics,
  ];
}

/// 默认开关表。
///
/// 与上游的差异：`time` 默认 true（见 [OsdFlag.time] 的注释）。
Map<String, bool> defaultOsdFlags() => {
  OsdFlag.title: true,
  OsdFlag.size: true,
  OsdFlag.time: true,
  OsdFlag.progress: true,
  OsdFlag.traffic: false,
  OsdFlag.mini: false,
  OsdFlag.diagnostics: false,
};

/// 把任意输入归一化成完整的 7 项开关表。
///
/// 规则（`docs/phase8/design/02` §5.2）：
/// - 未知键**忽略**（不抛异常，不写入结果）；
/// - 缺失键用 [defaultOsdFlags] 补齐；
/// - 非 `bool` 的值回落默认（手改文件写成 `"yes"` / `1` / `null` 时不让状态变脏）；
/// - 非 `Map` 输入整体回落默认。
///
/// 与 `UiThemeMode.normalize` 同一语义：**只接受合法值，其余回落默认**。
Map<String, bool> normalizeOsdFlags(Object? raw) {
  final defaults = defaultOsdFlags();
  if (raw is! Map) return defaults;
  final result = <String, bool>{};
  for (final id in OsdFlag.values) {
    final value = raw[id];
    result[id] = value is bool ? value : defaults[id]!;
  }
  return result;
}

/// 是否至少有一项屏显开启。
///
/// 全关时屏显层完全隐藏且停止刷新循环（`docs/phase8/design/02` §4.3）。
bool anyOsdEnabled(Map<String, bool> flags) => flags.values.any((on) => on);
