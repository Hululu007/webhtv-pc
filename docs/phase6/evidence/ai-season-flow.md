# Phase 6 · plans/04 Task 9 证据（AI 集季识别端到端 L3）

- 计划：`docs/phase6/plans/04-ai-episode-season.md`（Task 9）
- 设计：`docs/phase6/design/04`、`docs/phase6/design/05` §4.4 D19、§5.1
- 原始输出：`docs/phase6/evidence/ai-season-flow.txt`
- 测试文件：
  - `apps/desktop-flutter/integration_test/fixture_ai.dart`（假 AI 服务端）
  - `apps/desktop-flutter/integration_test/phase6_ai_season_flow_test.dart`（**7 个用例**）

## 1. 结果

```text
00:00 +0: D19：分析 → 预览 → 应用（KEEP_ORIGINAL 落盘）
00:07 +1: EXPLICIT_MAPPING 仅预览：没有「应用建议」
00:11 +2: FLAT_BY_COUNTS：应用前再校验 canAutoSlice（不匹配则拒绝落盘）
00:14 +3: HTTP 失败 → 只提示错误，绑定不变，不进预览
00:17 +4: 分析失败（硬校验拒绝）→ 提示且不落盘
00:20 +5: 取消分析 → 绑定不变，不进预览
00:26 +6: D12：未配置 AI → 弹窗引导，去设置且不误清绑定
00:31 +7: All tests passed!
```

命令：`flutter test integration_test/phase6_ai_season_flow_test.dart -d windows`

真实窗口 + 真实 HTTP + 真实 SQLite；AI 打到进程内 `FakeAiServer`，
TMDB 打到既有本地 fixture 服务。**不访问外部网络。**

## 2. 机器可读证据（测试内 `debugPrint`）

```text
matched=示例剧集 counts={0: 3, 1: 12, 2: 10} line=线路一 episodes=22 selected=1 canAutoSlice=false
applied=KEEP_ORIGINAL selected=-1 paths=[/v1/chat/completions]
flat-by-counts refused: canAutoSlice=false, binding=1
http-failure snackbar=1
ai-settings-page opened, binding=1
```

要点：
- `paths=[/v1/chat/completions]` —— 按 `openai_chat` 协议**只**打了该端点，
  证明请求规格构造正确（不是「发了但发错地方」）。
- `applied=KEEP_ORIGINAL selected=-1` —— 确认前 `selected=1`，
  确认后才变 `-1`，证明「必经确认才落盘」（P2）。
- `flat-by-counts refused: binding=1` —— 本地 `canAutoSlice` 校验不过时
  **不写绑定**（`design/04` §7.4）。
- `ai-settings-page opened, binding=1` —— 点「去配置 AI」进设置页，
  绑定**保持 1**，没有被解释成「清除手动绑定」（§7.1.1 的 D12）。

## 3. 覆盖的验收项

| # | 断言 | 用例 |
| --- | --- | --- |
| D19 | 分析 → 预览 → 应用 | `D19：分析 → 预览 → 应用` |
| D11 | `EXPLICIT_MAPPING` 只预览不落盘 | `EXPLICIT_MAPPING 仅预览` |
| D14 | `FLAT_BY_COUNTS` 应用前再校验 `canAutoSlice` | `FLAT_BY_COUNTS：应用前再校验 canAutoSlice` |
| D12 | 未配置 AI → 引导去设置，且不误清绑定 | `D12：未配置 AI → 弹窗引导...` |
| D15 | 取消分析不改动任何绑定 | `取消分析 → 绑定不变，不进预览` |
| — | 硬校验失败不落盘 | `分析失败（硬校验拒绝）` |
| — | 传输层失败不落盘 | `HTTP 失败 → 只提示错误` |

## 4. 走**真实 UI 路径**而不是状态层测试口子

计划 Task 9 原本用两个 `@visibleForTesting` 口子
（`runAiSeasonAnalysisForTest` / `openAiSettingsForTest`）绕过弹窗。
改成一律**点按钮**（季度按钮 → `tmdb-season-ai`），原因：

`_openSeasonDialog` 里那段「必须在 `bindTmdbSeason` 之前」的分流是
`design/04` §7.1.1 点名的**本轮最易写错之处**，绕过它就等于不测它。
实测正是这条路径揪出了下面这个 P0 缺陷。

代价：需要先滚过满屏 hero 才能点到季度按钮（`DetailPage` 正文是懒构建
`ListView`），已封装进 `openSeasonDialog()`。

## 5. 本轮 L3 揪出并修掉的 P0 缺陷

**季度弹窗的选择结果全部丢失 —— 用户点「第 2 季」看起来就是「点了没反应」。**

- 现象：`showDialog<TmdbSeasonChoice>` 声明了路由结果类型，但弹窗 `pop` 的是
  `_SeasonChoice`（私有枚举）或 `int`（季号），两者都不是 `TmdbSeasonChoice`。
  `Navigator.pop` 因此抛
  `A request was made to pop a route with a result of type int, but the route
  expected a value of type TmdbSeasonChoice`，对话框结果恒为 `null`。
- **存在时间：Phase 4 起**（引入 `showDialog<TmdbSeasonChoice>` 的
  `7ac0334`），本轮之前一直没被发现。
- 为什么既有测试没抓到：`phase4_tmdb_ui_test` 用的是
  `showDialog<Object?>` + `decodeSeasonChoice`（正是设计的写法），
  它测的是**设计的写法**；而 `lib/` 里从未接线 `decodeSeasonChoice`
  （`decodeSeasonChoice` 是**死代码**）。也就是说门禁测试与生产代码长期
  不一致，且没有任何 L3 驱动过真实弹窗。
- 修法：`browse_pages.dart` 改为 `showDialog<Object?>` + `decodeSeasonChoice(raw)`，
  即设计原本要求的写法。

## 6. 其他修正

1. **进度框关闭用 `pop()` 而不是 `maybePop()`**（`browse_pages.dart`）。
   `maybePop()` 会走 `Route.willPop()`，而 `ModalRoute.willPop()` 断言本路由的
   `_ModalScopeState` 已构建（`routes.dart`: `'scope != null'`）。假服务端回得
   快时，`await` 在进度框**第一帧之前**就返回，`maybePop()` 当场断言失败
   （实测 `'scope != null': is not true`）。`pop()` 不经过 `willPop()`。
   安全性：进度框 `barrierDismissible: false`，唯一退出路径是取消按钮
   （会置 `canceled`），故 `!canceled` 时栈顶必然是进度框。
2. **`fixture_ai.dart` 不兼做假 TMDB**（计划原写法）。`design/05` §5.1 把它
   定义为**按路径返回 AI 响应**的服务；TMDB 依赖已有既成 fixture 服务
   （全部 `integration_test/tmdb_*` 都在用，匹配数据与客户端已对齐）。
   另造一份最小 TMDB 必须补齐 `/configuration`、`/tv/<id>`、
   `/tv/<id>/season/<n>` 等一整串路由才不会让客户端走进异常分支。
3. **`EXPLICIT_MAPPING` 预置映射必须真的合法**：fixture 线路一 22 集 =
   TMDB S1 12 + S2 10，映射由代码按「严格递增」生成。若映射本身不合法，
   `parseAiSeasonResponse` 会先返回 `invalidMapping`，用例会「看起来通过」
   却一行预览都没走到。
4. **`FLAT_BY_COUNTS` 用例锁的是「安全拒绝」而不是「顺利应用」**：既有
   fixture 的 TMDB 含特别篇（S0 3 + S1 12 + S2 10 = 25），线路一只有 22 集，
   `canAutoSlice` 为 false。拒绝路径错了就是静默写坏绑定，比顺利路径更值得锁。
5. 三处 `find.textContaining` 因文案在「预览框」与「其后的弹窗」中同时出现而
   命中 2 个 widget，改为精确 `find.text` 或 `find.descendant(of: SnackBar)`。
6. 进度框断言需要 `fake.delay`（假服务端太快时进度框会在断言前就关闭）。

## 7. 尚未做完（收尾验证）

- [ ] `flutter analyze` 全量零告警核实
- [ ] 全量 `flutter test` 复跑核实（上一次尝试被中断，
      且中断残留在日志里表现为 `Connection closed before test suite loaded`，
      那**不是**真实失败）
- [ ] AI 设置页与预览框截图写入
      `docs/phase6/evidence/ai-settings.png` / `ai-season-preview.png`
      （`design/05` §6 要求；AI 设置页真机截图已在
      `ai-settings-page.png` 完成，**预览框截图仍缺**）
- [ ] 回填 `docs/webhtv-pc-design.md` §27.12 的取舍修订
- [ ] 更新 `docs/phase6/README.md` 阶段状态
- [ ] Key 不进日志的全局复查
