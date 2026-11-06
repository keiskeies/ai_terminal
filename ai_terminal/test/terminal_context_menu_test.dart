import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/terminal_context_menu.dart';

Widget _wrap(List<TerminalMenuItem> items, {required VoidCallback onDismiss}) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: Builder(
        builder: (context) => Stack(
          children: [
            TerminalContextMenu(
              position: const Offset(40, 40),
              items: items,
              onDismiss: onDismiss,
              tc: ThemeColors.of(context),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('点击菜单项触发回调并关闭菜单', (tester) async {
    var tapped = false;
    var dismissed = false;
    await tester.pumpWidget(_wrap(
      [
        TerminalMenuItem(
          label: '复制',
          icon: Icons.copy_rounded,
          onTap: () => tapped = true,
        ),
        TerminalMenuItem(label: '粘贴', onTap: () {}),
      ],
      onDismiss: () => dismissed = true,
    ));
    await tester.pump();

    await tester.tap(find.text('复制'));
    expect(tapped, isTrue);
    expect(dismissed, isTrue);
  });

  testWidgets('禁用项不触发回调', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(
      [
        TerminalMenuItem(
          label: '在终端执行这条命令',
          enabled: false,
          danger: true,
          onTap: () => tapped = true,
        ),
      ],
      onDismiss: () {},
    ));
    await tester.pump();

    await tester.tap(find.text('在终端执行这条命令'));
    expect(tapped, isFalse);
  });

  testWidgets('ESC 关闭菜单', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(_wrap(
      [TerminalMenuItem(label: '粘贴', onTap: () {})],
      onDismiss: () => dismissed = true,
    ));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('菜单项很多时限制高度并可滚动', (tester) async {
    await tester.pumpWidget(_wrap(
      [
        for (var i = 0; i < 20; i++)
          TerminalMenuItem(label: '项目 $i', onTap: () {}),
      ],
      onDismiss: () {},
    ));
    await tester.pump();

    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll, isNotNull);
    // 600 高的屏幕，菜单最多占 70%
    final menuBox = tester.getRect(find.byType(SingleChildScrollView));
    expect(menuBox.height, lessThanOrEqualTo(600 * 0.7 + 1));
  });

  testWidgets('分组分隔线按 separatorBefore 渲染', (tester) async {
    await tester.pumpWidget(_wrap(
      [
        TerminalMenuItem(label: '复制', onTap: () {}),
        TerminalMenuItem(label: '清屏', separatorBefore: true, onTap: () {}),
      ],
      onDismiss: () {},
    ));
    await tester.pump();

    // 分隔线是一个 1px 高的 Container
    expect(
      find.byWidgetPredicate((w) =>
          w is Container && w.constraints?.maxHeight == 1),
      findsOneWidget,
    );
    expect(find.text('清屏'), findsOneWidget);
  });
}
