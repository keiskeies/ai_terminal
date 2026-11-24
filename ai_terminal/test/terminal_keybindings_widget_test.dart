import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/terminal_keybindings.dart';
import 'package:ai_terminal/widgets/terminal_context_menu.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

/// 快捷键自定义的端到端验证。
///
/// 键表本身（解析/校验/匹配）在 terminal_keybindings_test.dart 里测透了，
/// 这里验的是**接线**：TerminalView 真的按传入的 keymap 分发，而不是还留着
/// 旧的硬编码 —— 那种回归光测键表抓不到。
void main() {
  late StringBuffer toShell;

  Future<void> pump(
    WidgetTester tester, {
    required xterm.Terminal terminal,
    TerminalKeymap? keymap,
    ValueChanged<double>? onFontSizeChanged,
    void Function()? onHistory,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(
            terminal: terminal,
            keymap: keymap,
            onFontSizeChanged: onFontSizeChanged,
            onMenuIntent: onHistory == null
                ? null
                : (intent, text) async {
                    if (intent == TerminalMenuIntent.showHistory) onHistory();
                  },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 按住修饰键敲主键。用左修饰键：keymap 读 HardwareKeyboard 的
  /// isControlPressed 等，与左右无关。
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    LogicalKeyboardKey? ctrl,
    LogicalKeyboardKey? alt,
    bool shift = false,
  }) async {
    if (ctrl != null) await tester.sendKeyDownEvent(ctrl);
    if (alt != null) await tester.sendKeyDownEvent(alt);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (alt != null) await tester.sendKeyUpEvent(alt);
    if (ctrl != null) await tester.sendKeyUpEvent(ctrl);
    await tester.pumpAndSettle();
  }

  const ctrl = LogicalKeyboardKey.controlLeft;
  const alt = LogicalKeyboardKey.altLeft;

  /// 有内容的终端；所有发往 shell 的字节记到 toShell
  xterm.Terminal readyTerminal() {
    final terminal = xterm.Terminal();
    toShell = StringBuffer();
    terminal.onOutput = toShell.write;
    terminal.write('hello world\r\nhello again\r\n');
    return terminal;
  }

  setUp(() => toShell = StringBuffer());

  group('默认键位与自定义之前的行为逐键一致', () {
    testWidgets('Ctrl+Shift+F 打开搜索', (tester) async {
      await pump(tester, terminal: readyTerminal());
      expect(find.byType(TextField), findsNothing);
      await press(tester, LogicalKeyboardKey.keyF, ctrl: ctrl, shift: true);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('Ctrl+Shift+H 触发命令历史', (tester) async {
      var calls = 0;
      await pump(tester, terminal: readyTerminal(), onHistory: () => calls++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl, shift: true);
      expect(calls, 1);
    });

    testWidgets('Ctrl+= / Ctrl+- / Ctrl+0 缩放（默认字号 13）', (tester) async {
      final sizes = <double>[];
      await pump(tester,
          terminal: readyTerminal(), onFontSizeChanged: sizes.add);
      await press(tester, LogicalKeyboardKey.equal, ctrl: ctrl);
      await press(tester, LogicalKeyboardKey.minus, ctrl: ctrl);
      await press(tester, LogicalKeyboardKey.digit0, ctrl: ctrl);
      // widget.fontSize 在本测试里始终是 13（页面才持有可变字号），
      // 所以每次都是相对 13 计算：+1 / -1 / 重置为 14
      expect(sizes, [14, 12, 14]);
    });

    testWidgets('数字小键盘 Ctrl+Num+ / Ctrl+Num0 也算缩放', (tester) async {
      final sizes = <double>[];
      await pump(tester,
          terminal: readyTerminal(), onFontSizeChanged: sizes.add);
      await press(tester, LogicalKeyboardKey.numpadAdd, ctrl: ctrl);
      await press(tester, LogicalKeyboardKey.numpad0, ctrl: ctrl);
      expect(sizes, [14, 14]);
    });

    testWidgets('shell 的键不抢：Ctrl+A 发到 shell 而不是触发 app 动作', (tester) async {
      final sizes = <double>[];
      var history = 0;
      final terminal = readyTerminal();
      await pump(tester,
          terminal: terminal,
          onFontSizeChanged: sizes.add,
          onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyA, ctrl: ctrl);
      expect(sizes, isEmpty);
      expect(history, 0);
      // Ctrl+A 要作为 readline 行首的 \x01 落到 shell，而不是被吞掉
      expect(toShell.toString(), contains(String.fromCharCode(1)));
    });

    testWidgets('Ctrl+H 仍是退格（历史面板必须带 Shift 才抢）', (tester) async {
      var history = 0;
      final terminal = readyTerminal();
      await pump(tester, terminal: terminal, onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl);
      expect(history, 0);
      expect(toShell.toString(), contains(String.fromCharCode(8)));
    });
  });

  group('自定义键位', () {
    testWidgets('改绑后新组合生效、旧组合失效', (tester) async {
      final keymap = TerminalKeymap.fromSettings({
        'search': ['ctrl+alt+g'],
      });
      await pump(tester, terminal: readyTerminal(), keymap: keymap);

      await press(tester, LogicalKeyboardKey.keyF, ctrl: ctrl, shift: true);
      expect(find.byType(TextField), findsNothing, reason: '旧组合还在生效');

      await press(tester, LogicalKeyboardKey.keyG, ctrl: ctrl, alt: alt);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('解绑（空数组）后按键回到 shell', (tester) async {
      final keymap = TerminalKeymap.fromSettings({
        'zoomReset': <Object?>[],
      });
      final sizes = <double>[];
      final terminal = readyTerminal();
      await pump(tester,
          terminal: terminal, keymap: keymap, onFontSizeChanged: sizes.add);
      await press(tester, LogicalKeyboardKey.digit0, ctrl: ctrl);
      expect(sizes, isEmpty);
      // 放行后字节要发出去（xterm 对 Ctrl+0 的编码），不能凭空消失
      expect(toShell.toString(), isNotEmpty);
    });

    testWidgets('改绑一个动作不影响其它动作的默认值', (tester) async {
      final keymap = TerminalKeymap.fromSettings({
        'search': ['ctrl+alt+g'],
      });
      var history = 0;
      await pump(tester,
          terminal: readyTerminal(),
          keymap: keymap,
          onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl, shift: true);
      expect(history, 1);
    });

    testWidgets('一个动作的多条组合都生效', (tester) async {
      final keymap = TerminalKeymap.fromSettings({
        'commandHistory': ['ctrl+alt+h', 'alt+f2'],
      });
      var history = 0;
      await pump(tester,
          terminal: readyTerminal(),
          keymap: keymap,
          onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl, alt: alt);
      expect(history, 1);
      await press(tester, LogicalKeyboardKey.f2, alt: alt);
      expect(history, 2);
    });

    testWidgets('设置改了立即生效，不必重开终端', (tester) async {
      final terminal = readyTerminal();
      var history = 0;

      await pump(tester, terminal: terminal, onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl, shift: true);
      expect(history, 1);

      // 换表：历史挪到 Alt+F3 之后，老键位不该再弹
      await pump(tester,
          terminal: terminal,
          keymap: TerminalKeymap.fromSettings({
            'commandHistory': ['alt+f3'],
          }),
          onHistory: () => history++);
      await press(tester, LogicalKeyboardKey.keyH, ctrl: ctrl, shift: true);
      expect(history, 1);

      await press(tester, LogicalKeyboardKey.f3, alt: alt);
      expect(history, 2);
    });

    testWidgets('写坏的裸键绑定不会劫持打字', (tester) async {
      final sizes = <double>[];
      final terminal = readyTerminal();
      await pump(tester,
          terminal: terminal,
          onFontSizeChanged: sizes.add,
          // 故意塞一条裸键（校验会拒绝它，但即使设置被手改成这样也不能劫持）
          keymap: TerminalKeymap.fromSettings({
            'zoomReset': ['digit0'],
          }));
      await press(tester, LogicalKeyboardKey.digit0);
      await press(tester, LogicalKeyboardKey.digit0, shift: true);
      expect(sizes, isEmpty);
      expect(find.byType(TextField), findsNothing);
    });
  });
}
