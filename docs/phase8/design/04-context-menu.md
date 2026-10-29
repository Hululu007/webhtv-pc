# 04 · 右键设置菜单

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：`F:\Workspace\webtv4\webhtv\app\src\main\java\com\fongmi\android\tv\ui\dialog\ControlDialog.java`
  （**内容**依据；上游无右键形态）
- 关联：`00` §4.5、`01` §4.6、`02` §6、`03` §6
- PC 端落点：新增 `apps/desktop-flutter/lib/ui/player_context_menu.dart`；
  修改 `apps/desktop-flutter/lib/ui/player_page.dart`

---

## 1. 目标

用桌面用户已经形成肌肉记忆的**右键**打开播放器设置，替代"点顶栏图标 → 弹出菜单"
的两步路径；并且**不打断播放**（不压暗、不暂停、不隐藏控制栏）。

---

## 2. 为什么上游不能直接抄

| 事实 | 位置 | 含义 |
| --- | --- | --- |
| 上游 `ControlDialog` 是**底部抽屉**（`BottomSheetDialogFragment`） | `ui/dialog/ControlDialog.java` | 移动端没有右键 |
| 上游手势只有单击/双击/长按/滑动/缩放 | `ui/custom/PlayerGesture.java` | 无右键语义 |
| 抽屉无遮罩（`setDimAmount(0f)`） | `ControlDialog.java:264-265` | 这个**可以**借鉴：设置面板不压暗画面 |

**结论**：形态由 PC 端自己定（右键 + 菜单），**内容**依据上游 `ControlDialog`。

---

## 3. 形态决策：不用 `Overlay`，用页内 `Stack` 层

### 3.1 问题

现有截图 harness（`integration_test/ui_redesign_visual_flow_test.dart:71-99`）
取树中**第一个 `RepaintBoundary`**（`Scaffold` 那层）：

```dart
final boundary = find.byType(RepaintBoundary);
final object = boundary.evaluate().first.renderObject;
```

`PopupMenu` / `MenuAnchor` / `showMenu` 渲染在 `Navigator` 的 `Overlay` 里，
**拍不到**。该文件里已有两处明确记录这个限制：

- `ui_redesign_visual_flow_test.dart:584-587`（筛选面板）
- `ui_redesign_visual_flow_test.dart:708-711`（播放器溢出菜单）

> "这里**不截图**：`PopupMenu` 渲染在 `Navigator` 的 `Overlay` 里，
> 而本 harness 的 `capture` 取的是树中第一个 `RepaintBoundary`（`Scaffold` 那一层），
> **拍不到浮层**。截出来的图与上一张逐字节相同，是假证据。"

### 3.2 决策

**右键菜单实现为 `PlayerPage` 的 `Stack` 子层，不用 `Overlay`。**

| 收益 | 说明 |
| --- | --- |
| **可截图** | 它在 `Scaffold` 的 `RepaintBoundary` 内，harness 能拍到**真实渲染**的菜单 |
| **可断言几何** | 可以断言菜单矩形、项数、分组标签，而不只是"文字存在" |
| 生命周期可控 | 不需要 `Navigator` 参与，`dispose` 时随页面一起销毁 |
| 与浮层模型一致 | `01` 已经把控制层做成 `Stack` 子层，菜单是同一模式的第 4 层 |

**代价**：需要自己实现"点击外部关闭"与"Esc 关闭"。
两者都是几行代码（`GestureDetector` 全屏透明层 + `CallbackShortcuts`），
远小于"拿不到视觉证据"的代价。

### 3.3 层级顺序（`01` §3 的扩展）

```
Stack:
  1. 画面 + 弹幕
  2. 屏显层（IgnorePointer）
  3. 控制浮层
  4. 右键菜单层（仅在打开时存在，带全屏透明遮罩用于"点外关闭"）
```

菜单在控制浮层**之上**，因为菜单往往是从控制浮层里的按钮触发的。

---

## 4. 菜单内容

### 4.1 分组与项

对齐 PotPlayer 的分组逻辑（**按功能域分组，不按使用频率**），
内容取自上游 `ControlDialog`（`ControlDialog.java:279-343`）与 PC 端既有能力：

| 分组 | 项 | 现状来源 | 键盘等价 |
| --- | --- | --- | --- |
| **播放** | 播放 / 暂停 | `controller.playOrPause` | 空格 |
| | 上一集 | `_playPrevious` | `[` |
| | 下一集 | `_playNext` | `]` |
| | 后退 10 秒 | `seekBy(-10s)` | ← |
| | 前进 10 秒 | `seekBy(+10s)` | → |
| **速度** | 0.5× / 0.75× / 1.0× / 1.25× / 1.5× / 2.0× | `controller.setRate` | 无（新增） |
| **画面** | 画面比例与缩放 ▸ | `_showVideoFitSettings` | 无 |
| | 全屏切换 | `_toggleFullscreen` | F11 / F |
| **轨道** | 字幕轨 ▸ | `_showSubtitleMenu` | 无 |
| | 弹幕开关 | `_toggleDanmaku` | 无 |
| | 弹幕设置… | `_showDanmakuSettings` | 无 |
| **显示** | 屏显 ▸（7 项开关） | `02` §5 | 无 |
| | 控制栏按钮… | `03` §6 | 无 |
| **信息** | 媒体信息 | `_showMediaInfo` | 无 |
| | 播放诊断 | `_showDiagnostics` | 无 |
| | 快捷键说明 | `_showShortcutHelp` | 无 |

### 4.2 去重纪律（`00` §5 第 10 条）

**菜单里的每一项都必须有非右键的等价路径。** 对照表：

| 菜单项 | 非右键路径 |
| --- | --- |
| 播放/暂停、上下集、快进快退 | 底部控制栏按钮 + 快捷键 |
| 倍速 | 底部控制栏 `DropdownButton` |
| 画面比例 | 顶栏「更多」菜单 |
| 全屏 | 底部控制栏 `IconButton` |
| 字幕轨 | **顶栏常驻按钮** |
| 弹幕开关 | **顶栏常驻按钮** |
| 弹幕设置 | 顶栏「更多」菜单 |
| 屏显开关 | **设置页新增「屏显」区块**（`02` §5 的配置页入口） |
| 控制栏按钮 | **设置页新增「播放器按钮」区块**（`03` §6.1） |
| 媒体信息 / 播放诊断 / 快捷键 | 顶栏「更多」菜单 |

**`屏显` 与 `控制栏按钮` 必须新增设置页入口**，否则它们**只有右键可达**，
违反第 10 条。这是本子系统唯一需要改动设置页的地方。

### 4.3 与顶栏「更多」菜单的关系

**不删除顶栏「更多」菜单。** 理由：

1. `ui_redesign_visual_flow_test.dart:696-707` 直接 `tap(find.byTooltip('更多'))`
   并断言 6 个菜单项文字存在。删掉它测试就红。
2. 右键不是唯一入口（§4.2），顶栏菜单是键盘/触控板用户的路径。

**因此存在两处入口指向同一批动作**——这是**有意的冗余**，
与 `DESIGN.md` 的"一个动作只有一个家"不冲突：那条规则针对的是
**同一层内**的重复（顶栏 vs 底部栏各放一个全屏按钮）。
右键菜单是**另一个交互维度**（快速访问层），它的存在理由就是"少点一次"。

**但必须避免第三种入口**：不得再往底部控制栏加"设置"按钮。

---

## 5. 交互细节

### 5.1 触发

| 触发 | 行为 |
| --- | --- |
| 画面区右键 | 在**指针位置**打开菜单 |
| 控制浮层上右键 | 同上（浮层不吞右键） |
| 屏显层右键 | 穿透到画面（屏显是 `IgnorePointer`） |

**实现**：在 `01` §3 的第 1 层 `GestureDetector` 上增加：

```dart
onSecondaryTapDown: (details) => _openContextMenu(details.globalPosition),
```

**注意**：`GestureDetector.onSecondaryTapDown` 在 Flutter 桌面可用，
但**必须同时处理 `onSecondaryTap`**（部分平台只发 tap 不发 tapDown）。
两个回调都指向同一个方法，方法内部做幂等（已打开则移动位置）。

### 5.2 位置与边界

菜单在指针位置打开，但**必须被约束在窗口内**：

```dart
final menuSize = const Size(240, 420);  // 估算值，实际用 LayoutBuilder 测量
final left = position.dx.clamp(8, viewport.width - menuSize.width - 8);
final top  = position.dy.clamp(8, viewport.height - menuSize.height - 8);
```

**为什么要 clamp**：在画面右下角右键，菜单会溢出窗口、部分项不可点。
这是桌面菜单的经典缺陷。

### 5.3 关闭

| 方式 | 实现 |
| --- | --- |
| 点击菜单外 | 全屏透明 `GestureDetector`（菜单层的兄弟，在菜单之下） |
| `Esc` | `CallbackShortcuts`（注意：`Esc` 现状是"退出全屏"，见下） |
| 选择任一项 | 执行动作后关闭 |
| 打开子菜单/对话框 | **不关闭**（子菜单在菜单内展开；对话框打开时菜单保持） |

**`Esc` 的冲突**：`buildPlayerShortcuts`（`app.dart:1154`）已把 `Esc` 绑定到
`exitFullscreen`。菜单打开时 `Esc` 应当**只关菜单**，不退出全屏。

**解法**：**不要**再嵌一层 `CallbackShortcuts`。菜单打开时，在**唯一的外层快捷键映射**上
按条件覆盖 `Esc`：

```dart
final shortcuts = buildPlayerShortcuts(...);
if (_contextMenuAnchor != null) {
  shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] = _closeContextMenu;
}
```

这样 `buildPlayerShortcuts` 本身不用改，而覆盖是确定性的。

> **为什么不能嵌一层（Task 11 实测踩到）**
>
> 本设计最初写的是「用一个更高优先级的 `CallbackShortcuts` 包住菜单层，
> 内层优先于外层（`Focus` 树的就近原则）」。**这是错的。**
>
> `CallbackShortcuts.build`（`flutter/lib/src/widgets/shortcuts.dart:1222`）返回的是
> `Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: ...)`。
> 按键派发在 `FocusManager` 里是**从主焦点节点向上遍历祖先**：
>
> ```dart
> // flutter/lib/src/widgets/focus_manager.dart:2276-2280
> for (final node in <FocusNode>[
>   FocusManager.instance.primaryFocus!,
>   ...FocusManager.instance.primaryFocus!.ancestors,
> ]) {
> ```
>
> 内层 `CallbackShortcuts` 是外层 `CallbackShortcuts` 的**后代**，而它是
> `canRequestFocus: false` + `skipTraversal: true`，**永远不会成为主焦点**，
> 也不在主焦点到根的路径上 → **它的 `onKeyEvent` 永远不会被调用**。
>
> 「就近原则」只在「内层节点是主焦点本身或其祖先」时成立——这里两个条件都不满足。
>
> 实测：按原设计实现后，「Esc 只关菜单，不退出全屏」用例失败
> （`Expected: no matching candidates / Actual: Found 1 widget with type "PlayerContextMenu"`）。
> 改成上面的条件覆盖后通过，且经变异验证（删掉覆盖即失败）。


### 5.4 与控制栏自动隐藏的联动（`01` §4.6）

| 事件 | 动作 |
| --- | --- |
| 菜单打开 | 强制 `_controlsVisible = true`，**取消**隐藏计时器 |
| 菜单打开期间 | 计时器不重排 |
| 菜单关闭 | 重新排 3 秒计时器 |

**为什么强制显示控制栏**：菜单里的"画面比例"、"字幕轨"等项会打开对话框，
用户从对话框返回时应当看到一个完整的控制栏，而不是空画面。

### 5.5 子菜单

「画面比例与缩放 ▸」「字幕轨 ▸」「屏显 ▸」是子菜单。

**实现选择**：**就地展开**（菜单内嵌一个可折叠区块），而不是飞出式子菜单。

| 方案 | 评价 |
| --- | --- |
| 飞出式子菜单 | 需要处理"飞出后超出窗口"、鼠标斜向移动丢失 hover 等经典难题 |
| **就地展开** | 菜单变高，但零悬停逻辑；且屏显的 7 个开关本来就需要一块区域 |
| 打开对话框 | 与"少点一次"的初衷冲突（右键 → 对话框 = 两次） |

**就地展开**是成本最低且最不容易出 bug 的。

### 5.6 视觉

| 项 | 值 | 依据 |
| --- | --- | --- |
| 底色 | `AppPalette.nightSurface3 @ 0.96` | 播放器页恒定暗色（`01` §4.3） |
| 圆角 | `AppRadius.mdAll`（10px） | `DESIGN.md` 弹出菜单用 10px |
| 边线 | 1px `outlineVariant @ 0.72` | `DESIGN.md` The Hairline Rule |
| elevation | **0** | `DESIGN.md` The Zero-Elevation Rule |
| 阴影 | **无** | 同上 |
| 宽度 | 240px | 与 `DESIGN.md` 的对话框量级一致 |
| 项高 | 36px | 桌面密度 |
| 分组标题 | `labelSmall` + `onSurfaceVariant` | 与列表项副标题一致 |
| 选中态 | 星等琥珀前景 | 当前倍速 / 当前画面模式 / 已开启的屏显项 |
| 禁用态 | 0.5 透明度 | `DESIGN.md` 的 chip 禁用语义 |

**"当前值"必须可见**：倍速菜单要标出当前档位，画面比例要标出当前模式，
屏显要显示开关状态。这是隐藏式菜单最容易丢的信息
（`DESIGN.md` 关于筛选面板的同类教训："必须显示已生效"）。

---

## 6. 与既有手势的兼容

| 手势 | 现状 | 本轮 |
| --- | --- | --- |
| 单击 | 切换控制栏 | **不变** |
| 双击 | 非全屏→全屏；全屏→播放暂停 | **不变** |
| 长按 | 2× 倍速 | **不变** |
| **右键** | 无 | **新增：打开菜单** |

**关键**：`resolvePlayerGesture`（`player_page.dart:156-164`）是纯函数且被
`phase3_player_display_test.dart:23-40` 锁定四个分支。**不得修改它的签名或返回值**。
右键是**独立回调**，不进入这个函数。

---

## 7. 验收清单

| # | 检查项 | 方式 |
| --- | --- | --- |
| C1 | 画面右键 → 菜单出现，且**在 `Scaffold` 的 `RepaintBoundary` 内**（可截图） | L3 截图 + `find.byType(PlayerContextMenu)` |
| C2 | 菜单矩形被约束在窗口内（右下角右键不溢出） | L2 widget 测试（`tester.getRect`） |
| C3 | 点击菜单外 → 关闭 | L2 widget 测试 |
| C4 | `Esc` → 只关菜单，**不退出全屏** | L2 widget 测试 |
| C5 | 打开菜单 → 控制栏强制可见且计时器取消 | L2 widget 测试 |
| C6 | 关闭菜单 → 3 秒后控制栏隐藏 | L2 widget 测试（`pump(3s)`） |
| C7 | 每一项都有非右键等价路径（对照 §4.2 表） | L1 源码扫描 + 人工核对 |
| C8 | 倍速菜单标出当前档位 | L2 widget 测试（选中态） |
| C9 | 屏显子菜单的 7 个开关状态正确 | L2 widget 测试 |
| C10 | 单击/双击/长按语义**未变** | 沿用 `phase3_player_display_test.dart` |
| C11 | 顶栏「更多」菜单仍存在且 6 项齐全 | 沿用 `ui_redesign_visual_flow_test.dart:696-707` |
| C12 | 菜单无阴影、elevation 0 | L1 源码扫描 |
| C13 | 设置页新增「屏显」与「播放器按钮」两个入口 | L2 widget 测试 |
