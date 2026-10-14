# 02 · 详情页：首屏按钮读历史续播 + 线路/选集高亮

- 状态：设计指导，**待评审**
- 日期：2026-10-14
- 上游参考：`webhtv/默影视` 的 `TmdbDetailActivity`（`updatePlayLabel` / `onPlay` /
  `initHistory` / `findInitialFlag` / `renderEpisodes`）、`TmdbUIAdapter#selectPlaybackFlag`、
  `InlineEpisodeAdapter`
- 关联：`00`（总索引 §3.2、§3.3）、`01`（历史页）、`03`（季度与选集分页）
- PC 端落点：`lib/ui/browse_pages.dart`（`DetailPage`）、`lib/ui/tmdb_detail_view.dart`
  （`TmdbLineSelector` / `TmdbEpisodeCardTile`）、`lib/core/history_view.dart`（新增）

---

## 1. 现状与缺口

| 项 | 现状 | 目标 |
| --- | --- | --- |
| 首屏按钮 | 硬编码 `播放第一集`，固定播 `_activeLine(lines)` 的第 0 集 | 读历史：命中 → `继续播放 · <集名>` 并播那一集 |
| 打开时的线路 | 恒为第一条（`_selectedLineFlag` 空串 → `lines.first`） | 自动切到历史线路 |
| 线路 chip 高亮 | 只有「当前选中」态 | 额外标出「最近播放」那条 |
| 选集卡片高亮 | **无任何历史标记** | 标出「上次看到这里」那一集 |

---

## 2. 历史解析（纯逻辑）

新增 `lib/core/history_view.dart` 中的解析函数，**不依赖 Flutter**：

```dart
/// 详情页从历史恢复播放的目标。
class HistoryResumeTarget {
  final String flag;          // 命中的线路 flag（空串表示未命中任何线路）
  final int episodeIndex;     // 该线路内的剧集下标（-1 表示未命中）
  final String episodeName;
  final Duration? position;   // 续播位置；null = 从头
  final bool matched;         // 是否真的命中了历史
}

HistoryResumeTarget resolveHistoryTarget({
  required PlaybackHistory? history,
  required List<VodPlayLine> lines,
});
```

### 2.1 线路匹配（对齐 `TmdbUIAdapter#selectPlaybackFlag`）

三级顺序，**任一级命中即返回**：

1. **精确 flag 命中**：`line.playbackFlag == history.flag`，且该线路**包含**
   `history.episodeId`（作为某集的 `url`）。若 flag 命中但该线路不含这一集 →
   降级到第 2 级。
2. **集 URL 唯一命中**：在所有线路里找包含 `history.episodeId` 的线路；
   **恰好一条**才算命中（对齐上游 `uniqueFlagForEpisodeUrl`：多条命中 = 歧义 = 不猜）。
3. **线路名命中**：`line.flag == history.flag`（PC 的 `flag` 与 `playbackFlag`
   在桥接合并时可能不同，故两级都试）。

全部未命中 → `flag` 取第一条线路、`episodeIndex = 0`、`matched = false`。

### 2.2 集匹配

在命中线路内按顺序尝试：

1. `episode.url == history.episodeId`（**精确**，这是主路径：历史存的就是站点入口目标）
2. `episode.name == history.episodeName`（集名兜底）
3. 都未命中 → 第 0 集，`matched = false`

**不按集号下标猜**：历史里没有集号字段（`PlaybackHistory` 只有 `episodeName` /
`episodeId`），按下标猜会把"第 5 集"记到"第 5 个位置"，而集号可能不连续。

### 2.3 续播位置

`position` 由调用方用既有的 `AppState.resumePositionFor(...)` 取（它已处理
`completed` 与位置过短两种情形）。解析函数**不重复实现**这段判定。

---

## 3. 首屏按钮

### 3.1 文案

| 条件 | 文案 | `ValueKey` |
| --- | --- | --- |
| `matched == true` 且未看完且有进度 | `继续播放 · <集名>` | `detail-hero-play` |
| 其余 | `播放第一集` | `detail-hero-play` |

`detail-hero-play` 这个 key **必须保留**：`phase3_detail_page_test` 按它断言
`findsOneWidget`。

「未看完且有进度」的判定复用 `resumePositionFor` 的结果（非 null 即可）。
不用 `history.completed` 单独判断——`resumePositionFor` 已经把 `completed`
与"位置过短"一起处理了，两处判断会漂移。

### 3.2 点击目标

```dart
onPressed: () => _play(
  vod,
  _activeLine(lines),
  target.episodeIndex,          // 命中的集，而不是硬编码 0
),
```

`_play(vod, line, episodeIndex)` 内部已经会调 `resumePositionFor` 带上起始位置
（`browse_pages.dart` 第 1110 行），所以**续播位置不需要额外传参**。

### 3.3 集下标必须换算

`target.episodeIndex` 是**线路原始下标**（`VodPlayLine.episodes` 的下标），
而渲染下标经过 TMDB 季度过滤与倒序。首屏按钮直接用原始下标调 `_play`，
**不经过** `_playEpisodeAt` 的换算——因为 `_play` 要的就是原始下标。
这一点容易搞反，实现时必须确认。

---

## 4. 打开详情页时自动选线路

`DetailPage` 新增可选参数，由历史页传入：

```dart
const DetailPage({
  super.key,
  required this.state,
  required this.vod,
  this.historyFlag = '',        // 历史命中的线路 flag
  this.historyEpisodeId = '',   // 历史命中的集入口目标
});
```

`initState` 里在 `loadDetail` 之前（或详情到达之后）应用：

- 详情到达后，用 `historyFlag` / `historyEpisodeId` 走 §2 的解析，
  把命中的线路写进 `_selectedLineFlag`；
- 同时调 `tmdb.selectLine(flag)`，让 TMDB 季度解析跟着走历史线路；
- 解析不出（历史线路已不存在）→ 保持第一条线路，**不报错**（历史可能来自
  旧配置或安卓推送，站点线路变了是正常情形）。

**为什么在详情到达之后**：`_activeLine(lines)` 依赖 `lines`，而 `lines` 在
详情请求返回前可能是列表页传入的残缺数据。在残缺数据上解析会得出错误线路。

---

## 5. 线路 chip 的「最近播放」标记

`TmdbLineSelector` 新增 `recentFlag`：

```dart
const TmdbLineSelector({
  ...
  this.recentFlag = '',    // 历史命中的线路 flag；空串 = 无标记
});
```

命中的 chip **在标签前**加一个 14px 的 `Icons.history` 图标 + tooltip
「最近播放」。**不改变** `selected` 语义（选中态仍是 `ChoiceChip` 的琥珀底，
`phase4_tmdb_ui_test` 与 `tmdb_detail_flow_test` 按 `tmdb-season-*` /
`tmdb-line-*` 的 key 与 `ChoiceChip` 类型断言，不可替换）。

自动选线路（§4）生效后，`recentFlag` 与 `selectedFlag` 通常相同——
标记仍有价值：用户手动切走后，标记还在，能切回来。

---

## 6. 选集卡片的「最近播放」标记

`TmdbEpisodeCardTile` 新增 `isRecent`：

```dart
const TmdbEpisodeCardTile({
  ...
  this.isRecent = false,
});
```

命中时的视觉：

- 卡片外壳（`OutlinedButton`）的 `side` 换成 `primary` 2px 描边；
- 剧照左上角原有的 `E<n>` 角标**旁边**加一个「上次看到这里」角标
  （`Icons.history` + 文字，`labelSmall`，底 `primaryContainer`）。

**外壳必须仍是 `OutlinedButton`**：既有集成门禁按
`widget is OutlinedButton && widget.key is ValueKey<String> && key.startsWith('episode-<flag>-')`
计数来断言「不补集」。换成裸 `InkWell` 会让那条门禁失效。

**剧照必须仍是 16:9**（`DESIGN.md` 的固定比例纪律，测试断言 ±0.1）。

---

## 7. 数据从哪来

### 7.1 两个来源，显式优先

`DetailPage` 的历史有两个来源：

| 来源 | 何时有 | 优先级 |
| --- | --- | --- |
| **构造参数** `historyFlag` / `historyEpisodeId` | 从历史页点卡片进入时 | **高** |
| **自己查** `state.findHistory(siteKey, vodId)` | 从列表页 / 搜索页进入时 | 低 |

```dart
final history = (widget.historyFlag.isNotEmpty || widget.historyEpisodeId.isNotEmpty)
    ? _historyFromParams()
    : state.findHistory(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
      );
```

**为什么参数优先**：历史页已经拿到了**用户点的那一条**。若让它去
`findHistory`，会命中 `ORDER BY updated_at DESC LIMIT 1` 的**另一条**
（同一部剧有多条记录时，点旧记录却续了新记录）。

`_historyFromParams()` 用一个最小 `PlaybackHistory` 承载传入的两个字段，
其余字段（`positionMs` 等）留默认——续播位置由 `resumePositionFor` 单独取，
不依赖这个对象。**不传 `positionMs`** 是有意的：历史页传入的是"哪条记录"，
不是"从哪一秒续"，后者由 `resumePositionFor` 按 `(siteKey, vodId, flag, episodeId)`
精确查询，避免两处位置判断漂移。

`findHistory` 已存在（`app_state.dart` 第 2303 行），按
`(siteKey, vodId)` 取最近一条（`ORDER BY updated_at DESC LIMIT 1`），
`flag` / `episodeId` 传 null 表示不限。

**注意**：`findHistory` 取的是该剧**最近一条**记录，可能是另一条线路的。
这正是 §2 三级匹配要处理的情形——历史线路可能不是当前线路。

**站点 key 的时序问题**：`state.selectedSite` 在详情页挂载时可能还没切到
正确站点（从历史页进入时已先切过，从搜索页进入时也已先切过）。若为 null，
`findHistory` 返回 null → 退化为「播放第一集」，**不报错**。

---

## 8. 验收

| # | 断言 |
| --- | --- |
| B1 | 无历史 → 按钮文案「播放第一集」，点击播第一条线路第 0 集 |
| B2 | 有历史且命中 → 按钮文案「继续播放 · <集名>」，点击播**那一集** |
| B3 | 有历史但已看完 → 按钮文案回到「播放第一集」（`resumePositionFor` 返回 null） |
| B4 | 有历史但位置过短 → 同上 |
| B5 | 历史线路已不存在 → 退回第一条线路，不报错 |
| B6 | 历史集入口目标在多条线路里都出现 → 判定歧义，退回第一条线路 |
| B7 | 打开详情页时自动切到历史线路（`_selectedLineFlag == history.flag`） |
| B8 | 线路 chip 上出现「最近播放」标记，且该 chip 仍可点击切换 |
| B9 | 选集卡片上出现「上次看到这里」标记，外壳仍是 `OutlinedButton` |
| B10 | 剧照仍是 16:9 |
| B11 | `detail-hero-play` key 仍存在 |
| B12 | 从历史页点卡片进详情页时，站点已先切换（不串站） |
