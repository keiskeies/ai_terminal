import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/utils/terminal_search.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

void main() {
  group('纯文本搜索（findTextMatches）', () {
    test('基本命中：行号 + 字符区间', () {
      final matches = findTextMatches(['hello world', 'say hello'], 'hello');
      expect(matches.length, 2);
      expect(matches[0].line, 0);
      expect(matches[0].start, 0);
      expect(matches[0].end, 5);
      expect(matches[1].line, 1);
      expect(matches[1].start, 4);
      expect(matches[1].end, 9);
    });

    test('默认忽略大小写', () {
      final matches = findTextMatches(['Hello HELLO hello'], 'hello');
      expect(matches.length, 3);
    });

    test('caseSensitive=true 只命中同大小写', () {
      final matches =
          findTextMatches(['Hello HELLO hello'], 'hello', caseSensitive: true);
      expect(matches.length, 1);
      expect(matches[0].start, 12);
    });

    test('空 query → 无命中', () {
      expect(findTextMatches(['abc'], ''), isEmpty);
    });

    test('一行多个命中不重叠', () {
      final matches = findTextMatches(['ababab'], 'ab');
      expect(matches.length, 3);
      expect(matches.map((m) => m.start).toList(), [0, 2, 4]);
    });

    test('query 按字面量处理：正则元字符不生效', () {
      // 'a.b' 不应匹配 'axb'
      expect(findTextMatches(['axb'], 'a.b'), isEmpty);
      expect(findTextMatches(['a.b'], 'a.b').length, 1);
    });

    test('大小写折叠不漂移下标（İ 这类 toLowerCase 会变长的字符）', () {
      final matches = findTextMatches(['İstanbul istanbul'], 'istanbul');
      expect(matches.length, 1);
      expect(matches[0].start, 9);
    });
  });

  group('buffer 桥接（searchTerminalBuffer）', () {
    test('ASCII：命中换算成 cell 列', () {
      final terminal = xterm.Terminal();
      terminal.write('hello world\r\nhello again\r\n');
      final matches = searchTerminalBuffer(terminal.buffer, 'hello');
      expect(matches.length, 2);
      expect(matches[0].line, 0);
      expect(matches[0].start, 0);
      expect(matches[0].end, 5);
      expect(matches[1].line, 1);
    });

    test('宽字符：字符串下标 → cell 列（你好 占 4 列）', () {
      final terminal = xterm.Terminal();
      terminal.write('你好world\r\n');
      final matches = searchTerminalBuffer(terminal.buffer, 'world');
      expect(matches.length, 1);
      expect(matches[0].start, 4);
      expect(matches[0].end, 9);
    });

    test('命中以宽字符结尾：end 含第二个 cell', () {
      final terminal = xterm.Terminal();
      terminal.write('abc你好\r\n');
      // a=0 b=1 c=2 你=3,4 好=5,6
      final matches = searchTerminalBuffer(terminal.buffer, '好');
      expect(matches.length, 1);
      expect(matches[0].start, 5);
      expect(matches[0].end, 7);
    });

    test('maxMatches 封顶', () {
      final terminal = xterm.Terminal();
      terminal.write('x\r\nx\r\nx\r\n');
      final matches = searchTerminalBuffer(terminal.buffer, 'x', maxMatches: 2);
      expect(matches.length, 2);
    });

    test('空 query → 无命中', () {
      final terminal = xterm.Terminal();
      terminal.write('abc\r\n');
      expect(searchTerminalBuffer(terminal.buffer, ''), isEmpty);
    });
  });

  group('搜索栏 widget 集成', () {
    Future<void> pumpTerminal(
        WidgetTester tester, xterm.Terminal terminal) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: TerminalView(terminal: terminal),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> openSearch(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('Ctrl+Shift+F 打开搜索栏，输入后显示命中计数', (tester) async {
      final terminal = xterm.Terminal();
      terminal.write('hello world\r\nhello again\r\n');
      await pumpTerminal(tester, terminal);

      expect(find.byType(TextField), findsNothing);
      await openSearch(tester);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      // Enter → 下一个命中
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);

      // Esc 关闭
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('无结果时显示「无结果」', (tester) async {
      final terminal = xterm.Terminal();
      terminal.write('hello\r\n');
      await pumpTerminal(tester, terminal);
      await openSearch(tester);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('无结果'), findsOneWidget);
    });

    testWidgets('区分大小写开关改变命中数', (tester) async {
      final terminal = xterm.Terminal();
      terminal.write('Hello hello\r\n');
      await pumpTerminal(tester, terminal);
      await openSearch(tester);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      await tester.tap(find.text('Aa'));
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('命中在回滚区时视图向上滚动', (tester) async {
      final terminal = xterm.Terminal();
      // 300 行输出，目标词只在第 0 行：打开搜索前视图贴底，
      // 输入查询后应跳到顶部附近。
      terminal.write('needle at top\r\n');
      for (var i = 0; i < 300; i++) {
        terminal.write('filler line $i\r\n');
      }
      await pumpTerminal(tester, terminal);

      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      final bottomOffset = scrollable.position.pixels;
      expect(bottomOffset, greaterThan(0));

      await openSearch(tester);
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
      expect(scrollable.position.pixels, lessThan(bottomOffset));
    });
  });
}
