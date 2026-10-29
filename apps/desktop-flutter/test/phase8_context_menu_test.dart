import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Stack(children: [child])),
);

/// 菜单本体的矩形。
///
/// 用菜单里的 `Material` 而不是 `find.byType(PlayerContextMenu)`：后者返回的是
/// `Positioned` 的产物，能证明「菜单在哪儿」，但「菜单多大」要落在真正的表面上。
Finder get menuSurface => find
    .descendant(
      of: find.byType(PlayerContextMenu),
      matching: find.byType(Material),
    )
    .first;

/// 深色主题下的角色值（菜单恒定跑在播放器页的暗色主题上，`design/01` §4.3）。
final ColorScheme darkScheme = buildAppTheme(Brightness.dark).colorScheme;

void main() {
  group('位置 clamp（design/04 §5.2）', () {
    test('左上角锚点不偏移', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(10, 10),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin, const Offset(10, 10));
    });

    test('右下角锚点被拉回窗口内', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(1430, 890),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx + 240, lessThanOrEqualTo(1440));
      expect(origin.dy + 420, lessThanOrEqualTo(900));
      // 正向断言精确值，而不是只关心「没超出」：只把 x 拉回、y 不管的实现
      // 也能过上面两条之外的那一条（`origin.dy = 890` 时 890 + 420 = 1310 会
      // 超出，但把 menuSize 当 0 的实现同样过），所以这里钉住两个分量。
      expect(origin, const Offset(1192, 472));
    });

    test('菜单比窗口还大时贴左上角', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(500, 500),
        viewport: const Size(200, 200),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx, 8);
      expect(origin.dy, 8);
    });

    test('负坐标锚点（多屏/任务栏外的全局坐标）也贴留白', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(-40, -12),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin, const Offset(8, 8));
    });
  });

  group('菜单渲染（design/04 §4.1、§5.6）', () {
    testWidgets('菜单是 Scaffold 的后代（页内 Stack 层，不是 Navigator 的 Overlay）', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 这是本任务的核心设计决定（`design/04` §3）：截图 harness 取树中第一个
      // `RepaintBoundary`（`Scaffold` 那层），菜单必须是 **`Scaffold` 的后代**
      // 才拍得到。`showMenu` / `MenuAnchor` 把菜单挂到 `Navigator` 的 `Overlay`
      // 上，而 `Overlay` 是 `Scaffold` 的**祖先**，于是这条断言会红。
      // （`design/05` §4 反向验证 #7 的 L2 版本；L3 版本是 Task 13 的截图对比。）
      expect(
        find.descendant(
          of: find.byType(Scaffold),
          matching: find.byType(PlayerContextMenu),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(PlayerContextMenu),
          matching: find.byType(Scaffold),
        ),
        findsOneWidget,
      );
    });

    testWidgets('分组标题与项都渲染', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(id: 'play', label: '播放 / 暂停'),
                  PlayerMenuItem(id: 'prev', label: '上一集'),
                ],
              ),
              PlayerMenuSection(
                title: '速度',
                items: [PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true)],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('速度'), findsOneWidget);
      expect(find.text('播放 / 暂停'), findsOneWidget);
      expect(find.text('1.0×'), findsOneWidget);
      // 分组标题用 labelSmall + onSurfaceVariant（design/04 §5.6）。
      final title = tester.widget<Text>(find.text('速度'));
      expect(title.style?.color, darkScheme.onSurfaceVariant);
      expect(title.style?.fontSize, 11);
    });

    testWidgets('禁用项不可点（design/04 §5.6）', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '信息',
                items: [
                  PlayerMenuItem(
                    id: 'diag',
                    label: '播放诊断',
                    enabled: false,
                    onSelect: () => tapped = true,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('播放诊断'));
      await tester.pump();
      expect(tapped, isFalse);
      // 正向断言「为什么不可点」：回调根本没挂上，而不是靠某个手势竞技场
      // 恰好没抢到。
      final row = tester.widget<InkWell>(
        find
            .ancestor(of: find.text('播放诊断'), matching: find.byType(InkWell))
            .first,
      );
      expect(row.onTap, isNull);
      // 禁用态 = onSurfaceVariant @ 0.5（design/04 §5.6）。
      expect(
        tester.widget<Text>(find.text('播放诊断')).style?.color,
        darkScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
    });

    testWidgets('选中项用星等琥珀（design/04 §5.6）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '速度',
                items: [
                  PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true),
                  PlayerMenuItem(id: 'rate_2', label: '1.5×'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final selected = tester.widget<Text>(find.text('1.0×'));
      final unselected = tester.widget<Text>(find.text('1.5×'));
      expect(selected.style?.color, isNot(unselected.style?.color));
      // 精确值：星等琥珀（`AppPalette.magnitude`，暗色主题下就是它）。
      expect(selected.style?.color, AppPalette.magnitude);
      expect(unselected.style?.color, darkScheme.onSurface);
      // 「必须显示已生效」（design/04 §5.6）：除了前景色，还有对勾标记。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_1')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_2')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
      // 恰好一个对勾：把每个项都打勾的实现也要红。
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('点击项执行回调（不自动关闭，由调用方决定）', (tester) async {
      var tapped = '';
      var dismissed = 0;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(
                    id: 'play',
                    label: '播放 / 暂停',
                    onSelect: () => tapped = 'play',
                  ),
                ],
              ),
            ],
            onDismiss: () => dismissed++,
          ),
        ),
      );
      await tester.tap(find.text('播放 / 暂停'));
      await tester.pump();
      expect(tapped, 'play');
      // 关闭是调用方的事（`player_page.dart` 在 onSelect 里自己关）：
      // 菜单自己再关一次会把「打开子菜单/对话框不关闭」这条规则搞坏。
      expect(dismissed, 0);
    });

    testWidgets('菜单被约束在窗口内（design/04 §5.2）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 1440,
            height: 900,
            child: Stack(
              children: [
                PlayerContextMenu(
                  anchor: const Offset(1430, 890),
                  viewport: const Size(1440, 900),
                  sections: const [
                    PlayerMenuSection(
                      title: '播放',
                      items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
                    ),
                  ],
                  onDismiss: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PlayerContextMenu));
      expect(rect.right, lessThanOrEqualTo(1440));
      expect(rect.bottom, lessThanOrEqualTo(900));
    });

    testWidgets('无阴影、elevation 0（DESIGN.md The Zero-Elevation Rule）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      for (final m in tester.widgetList<Material>(find.byType(Material))) {
        expect(m.elevation, 0);
      }
    });

    testWidgets('几何：左上角等于 clamp 后的锚点，宽度 240、项高 36（§5.2、§5.6）', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(1430, 890),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(id: 'play', label: '播放 / 暂停'),
                  PlayerMenuItem(id: 'next', label: '下一集'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 左上角 = clampMenuOrigin 的结果（不是窗口左上角，也不是锚点原值）。
      // 这一条同时排除「铺一层 Positioned.fill 全屏遮罩」和「进 Overlay」两种
      // 实现：前者左上角是 (0,0)，后者根本不在这个坐标空间。
      expect(tester.getTopLeft(menuSurface), const Offset(1192, 472));
      expect(tester.getSize(menuSurface).width, 240);
      // 项高 36（design/04 §5.6）。
      expect(
        tester.getSize(find.byKey(const ValueKey('player-menu-item-play'))),
        const Size(240, 36),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('player-menu-item-next'))),
        const Size(240, 36),
      );
    });

    testWidgets('表面与发丝边：nightSurface3 @ 0.96 + 1px outlineVariant @ 0.72', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final material = tester.widget<Material>(menuSurface);
      expect(material.elevation, 0);
      // 底色 design/04 §5.6：nightSurface3 @ 0.96。
      expect(material.color, AppPalette.nightSurface3.withValues(alpha: 0.96));
      final shape = material.shape! as RoundedRectangleBorder;
      // 圆角 = AppRadius.mdAll（10px）。
      expect(shape.borderRadius, AppRadius.mdAll);
      // 发丝边 1px 且是 outlineVariant @ 0.72（暗色下就是 nightLine）。
      // 断言的是 `shape` 而不是另包的 DecoratedBox：`Material` 用
      // `ShapeBorderClipper` 裁内容，边由同一套实现画出，1px 不会被裁掉半像素。
      expect(shape.side.width, 1.0);
      expect(shape.side.color, AppPalette.nightLine.withValues(alpha: 0.72));
      expect(material.shape, isNot(isA<StadiumBorder>()));
    });

    testWidgets('图标按 item.icon 渲染', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(
                    id: 'play',
                    label: '播放 / 暂停',
                    icon: Icons.play_arrow,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-play')),
          matching: find.byIcon(Icons.play_arrow),
        ),
        findsOneWidget,
      );
    });

    testWidgets('子菜单就地展开/收起，且展开项不发动作（design/04 §5.5）', (
      tester,
    ) async {
      var parentSelected = 0;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    icon: Icons.tune,
                    onSelect: () => parentSelected++,
                    children: const [
                      PlayerMenuItem(id: 'osd_title', label: '标题', selected: true),
                      PlayerMenuItem(id: 'osd_clock', label: '时钟'),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 收起态：子项不渲染，箭头朝下。
      expect(find.text('标题'), findsNothing);
      expect(find.text('时钟'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsNothing);

      await tester.tap(find.text('屏显'));
      await tester.pump();
      // 展开态：子项在菜单内出现（不是飞出式子菜单，所以仍在本 widget 子树里）。
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('时钟'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      // 带子菜单的项本身不发动作，否则一次点击会同时「展开」和「执行」。
      expect(parentSelected, 0);
      // 子项自己的选中态仍然可见（屏显开关状态要能读）。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-osd_title')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );

      // 再点一次收起。
      await tester.tap(find.text('屏显'));
      await tester.pump();
      expect(find.text('标题'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('内容比可用空间高时：菜单压到可用高度并在内部滚动，不溢出窗口', (
      tester,
    ) async {
      // 20 项 ≈ 751px，远超「锚点以下」的 492px。这是真实内容（6 组 + 展开的
      // 屏显 7 项）在 900px 窗口里的形状；用 420 的估值 clamp 之后如果不把
      // 高度压到左上角以下，菜单会伸到窗口外沿外且滚不到。
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(800, 600),
            sections: [
              PlayerMenuSection(
                title: '信息',
                items: [
                  for (var i = 0; i < 20; i++)
                    PlayerMenuItem(id: 'info_$i', label: '项 $i'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final rect = tester.getRect(menuSurface);
      expect(rect.top, 100);
      // 上限 = 视口高 - 左上角 - 留白 = 600 - 100 - 8。
      expect(rect.height, 492);
      expect(rect.bottom, lessThanOrEqualTo(600 - 8));
      // 超出部分真的可滚：内容高于视口。
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('窗口比 240 还窄时收窄菜单，右边缘仍留在留白内', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(150, 150),
            viewport: const Size(200, 200),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final rect = tester.getRect(menuSurface);
      expect(rect.left, 8);
      expect(rect.width, 200 - 2 * 8);
      expect(rect.right, lessThanOrEqualTo(200 - 8));
      expect(rect.bottom, lessThanOrEqualTo(200 - 8));
    });
  });

  group('契约守卫（design/04 §4.1）', () {
    // 关键用例：**二级子菜单必须在构造期被拒绝**。
    //
    // 为什么必须有这一条：`_row` 会给任何 `children` 非空的项画一个展开箭头，
    // 但 `_itemWidgets` 只为**顶层**项渲染孩子。若允许第二层存在，
    // 用户会看到一个**点了没反应**的箭头——静默失效，最难发现的一类缺陷。
    // 变异测试实测确认：去掉那条 `assert`，本用例会失败。
    testWidgets('二级子菜单在构造期断言失败（不做半套）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'aspect',
                    label: '画面比例',
                    children: [
                      PlayerMenuItem(
                        id: 'aspect-16-9',
                        label: '16:9',
                        // 第二层自己还有孩子 → 不被支持。
                        children: [PlayerMenuItem(id: 'deep', label: '更深一层')],
                      ),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 展开第一层，触发对第二层的检查。
      await tester.tap(find.text('画面比例'));
      await tester.pump();
      expect(
        tester.takeException(),
        isA<AssertionError>(),
        reason: '二级子菜单必须被显式拒绝，而不是画一个点不动的箭头',
      );
    });

    // 关键用例：**禁用不能抹掉选中态**（`DESIGN.md:373`）。
    //
    // 为什么必须有这一条：`DESIGN.md:373` 明确写着「禁用只降低强调，
    // **不能抹掉状态**」，并记录了一次真实用户反馈（把 `onTap == null`
    // 一律当静态标签，导致整排控件「长得一模一样且点不动」）。
    // 原实现把「选中 + 禁用」压成中性灰，琥珀完全消失。
    // 变异测试实测确认：改回中性灰，本用例会失败。
    testWidgets('选中且禁用时仍保留琥珀（只是压暗）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '倍速',
                items: [
                  PlayerMenuItem(
                    id: 'rate-1',
                    label: '1.0×',
                    selected: true,
                    enabled: false,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final color = tester.widget<Text>(find.text('1.0×')).style?.color;
      expect(
        color,
        AppPalette.magnitude.withValues(alpha: 0.5),
        reason: '禁用时压暗琥珀，而不是换成中性灰（DESIGN.md:373）',
      );
      // 反向：不得等于中性灰——那正是被修掉的行为。
      expect(color, isNot(darkScheme.onSurfaceVariant.withValues(alpha: 0.5)));
    });
  });
}
