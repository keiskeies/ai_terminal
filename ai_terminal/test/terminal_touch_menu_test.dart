import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/widgets/terminal_context_menu.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

/// 终端刻意偏移摆放：菜单锚点曾经多套一层 localToGlobal，会额外加上终端自己的
/// 偏移量。终端贴在 (0,0) 时这个 bug 完全看不见，所以这里必须偏移。
Future<void> pumpOffsetTerminal(
    WidgetTester tester, xterm.Terminal terminal) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.only(top: 200, left: 100),
        child: SizedBox(
          width: 600,
          height: 400,
          child: TerminalView(terminal: terminal),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 菜单容器的落点（Positioned 的 left/top，未经屏幕边缘回弹）。
/// 背景关闭层用 Positioned.fill（四边都设），菜单只设 left/top。
Offset menuAnchor(WidgetTester tester) {
  final positioned = tester
      .widgetList<Positioned>(find.descendant(
        of: find.byType(TerminalContextMenu),
        matching: find.byType(Positioned),
      ))
      .firstWhere((p) => p.left != null && p.right == null);
  return Offset(positioned.left!, positioned.top!);
}

void main() {
  testWidgets('触摸长按在手指处弹出复制/粘贴菜单', (tester) async {
    final terminal = xterm.Terminal()..write('hello world\n');
    await pumpOffsetTerminal(tester, terminal);

    final box = tester.getRect(find.byType(TerminalView));
    final at = box.topLeft + const Offset(30, 10);
    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.addPointer(location: at);
    await gesture.down(at);
    // 600ms 长按阈值，且要晚于 xterm 的 500ms 选词，菜单里才有选区可复制
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget,
        reason: '长按应先完成 xterm 选词，菜单才带复制项');
    expect(menuAnchor(tester), at,
        reason: '菜单要落在手指处，不能再加终端自身的偏移');

    await gesture.up();
    await tester.pump();
  });

  testWidgets('手指移动（滚动/扩选）不弹菜单', (tester) async {
    final terminal = xterm.Terminal()..write('hello world\n');
    await pumpOffsetTerminal(tester, terminal);

    final box = tester.getRect(find.byType(TerminalView));
    final at = box.topLeft + const Offset(30, 10);
    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.touch);
    await gesture.addPointer(location: at);
    await gesture.down(at);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(at + const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('粘贴'), findsNothing);

    await gesture.up();
    await tester.pump();
  });

  testWidgets('右键同样落在点击处', (tester) async {
    final terminal = xterm.Terminal()..write('hello world\n');
    await pumpOffsetTerminal(tester, terminal);

    final box = tester.getRect(find.byType(TerminalView));
    final at = box.topLeft + const Offset(30, 10);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.addPointer(location: at);
    await gesture.down(at);
    await tester.pumpAndSettle();

    expect(find.text('粘贴'), findsOneWidget);
    expect(menuAnchor(tester), at);

    await gesture.up();
    await tester.pump();
  });
}
