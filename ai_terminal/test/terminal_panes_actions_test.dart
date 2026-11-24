import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/core/terminal_keybindings.dart';
import 'package:ai_terminal/utils/terminal_panes.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

/// 分屏的**接线**验证（布局模型本身在 terminal_panes_test.dart 里测透了）。
///
/// 这里盯的是三件重构时最容易悄悄坏掉的事：
/// 1. 快捷键真的落到页面给出的回调上，而不是接了个空；
/// 2. 不该吞的键在「不能分屏 / 没分屏」时放行给 shell —— 抢键比少个功能更糟；
/// 3. 焦点落到哪一屏会回报给页面：Windows 原生 IME 只认一个投递目标，
///    报错就会把中文送进另一屏。
void main() {
  late StringBuffer toShell;
  late List<String> log;

  TerminalPaneActions actions({
    String paneId = 'tab1',
    bool isPrimary = true,
    bool isSplit = true,
    bool canSplit = true,
  }) =>
      TerminalPaneActions(
        paneId: paneId,
        isPrimary: isPrimary,
        isSplit: isSplit,
        canSplit: canSplit,
        onSplit: (d) => log.add('split:${d.id}'),
        onClose: () => log.add('close'),
        onFocusNeighbor: (f) => log.add('focus:${f ? 'next' : 'prev'}'),
        onFocus: () => log.add('focus-on'),
      );

  Future<void> pump(
    WidgetTester tester, {
    required xterm.Terminal terminal,
    TerminalPaneActions? panes,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(terminal: terminal, panes: panes),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 按住修饰键敲主键（与 terminal_keybindings_widget_test 同一套写法）
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool ctrl = false,
    bool shift = false,
    bool meta = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(key);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Offset at) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.addPointer(location: at);
    await gesture.down(at);
    await tester.pumpAndSettle();
  }

  // maxLines 必须 ≥ 行数：xterm 4.0.0 的 Buffer 构造预推 viewHeight 行，
  // maxLines 小于 rows 时 resize 会撞上 "Cannot pop from an empty list"。
  xterm.Terminal readyTerminal() {
    final terminal = xterm.Terminal(maxLines: 30);
    toShell = StringBuffer();
    terminal.onOutput = toShell.write;
    terminal.write('hello\r\n');
    return terminal;
  }

  setUp(() {
    toShell = StringBuffer();
    log = [];
  });

  /// autofocus 会立刻回报一次焦点（真实行为，不是噪声：页面据此记活动 pane）。
  /// 按键类断言只关心随后的动作，所以先清掉这一条。
  Future<void> pumpClean(
    WidgetTester tester, {
    required xterm.Terminal terminal,
    TerminalPaneActions? panes,
  }) async {
    await pump(tester, terminal: terminal, panes: panes);
    log.clear();
  }

  group('快捷键落到页面回调', () {
    testWidgets('Ctrl+Shift+D 请求左右分屏', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.keyD, ctrl: true, shift: true);
      expect(log, ['split:vertical']);
    });

    testWidgets('Ctrl+Shift+S 请求上下分屏', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.keyS, ctrl: true, shift: true);
      expect(log, ['split:horizontal']);
    });

    testWidgets('Ctrl+Shift+W 关掉这一屏', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      expect(log, ['close']);
    });

    testWidgets('焦点前移/后移各走自己的方向', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.period, ctrl: true, shift: true);
      await press(tester, LogicalKeyboardKey.comma, ctrl: true, shift: true);
      expect(log, ['focus:next', 'focus:prev']);
    });

    testWidgets('mac 的 ⌘D / ⌘⇧D 同样生效', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.keyD, meta: true);
      await press(tester, LogicalKeyboardKey.keyD, meta: true, shift: true);
      expect(log, ['split:vertical', 'split:horizontal']);
    });
  });

  group('不该吞的键要放行', () {
    testWidgets('已到上限时分屏键不吞、不回调', (tester) async {
      await pumpClean(tester,
          terminal: readyTerminal(), panes: actions(canSplit: false));
      await press(tester, LogicalKeyboardKey.keyD, ctrl: true, shift: true);
      expect(log, isEmpty);
    });

    testWidgets('未分屏时关闭/移焦点键不吞', (tester) async {
      await pumpClean(tester,
          terminal: readyTerminal(), panes: actions(isSplit: false));
      await press(tester, LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      await press(tester, LogicalKeyboardKey.period, ctrl: true, shift: true);
      expect(log, isEmpty);
    });

    testWidgets('panes=null（不参与分屏）时这些键全部交回 shell', (tester) async {
      await pump(tester, terminal: readyTerminal(), panes: null);
      await press(tester, LogicalKeyboardKey.keyD, ctrl: true, shift: true);
      await press(tester, LogicalKeyboardKey.keyW, ctrl: true, shift: true);
      expect(log, isEmpty);
    });

    testWidgets('裸 d 照常落到 shell 命令行，且不触发分屏', (tester) async {
      await pumpClean(tester, terminal: readyTerminal(), panes: actions());
      await press(tester, LogicalKeyboardKey.keyD);
      expect(log, isEmpty);
      expect(toShell.toString(), contains('d'));
    });
  });

  group('焦点归属', () {
    testWidgets('这一屏拿到键盘焦点时回报页面', (tester) async {
      await pump(tester, terminal: readyTerminal(), panes: actions());
      expect(log, contains('focus-on'));
    });

    testWidgets('焦点被别处抢走后，点击这一屏重新回报', (tester) async {
      await pump(tester,
          terminal: readyTerminal(),
          panes: actions(paneId: 'tab1#p1', isPrimary: false));
      // 先把焦点交出去，否则 requestFocus 是 no-op，listener 不会回调
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      log.clear();
      await tester.tap(find.byType(TerminalView));
      // xterm 的 tap 处理会起一个 300ms 双击判定定时器，且不排帧，
      // pumpAndSettle 不会推进它 —— 不手动跨过 300ms 会报 pending timer。
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(log, contains('focus-on'));
    });
  });

  group('右键菜单', () {
    testWidgets('出现左右/上下分屏两项，且带快捷键提示', (tester) async {
      await pump(tester, terminal: readyTerminal(), panes: actions());
      await rightClick(tester, const Offset(30, 10));
      expect(find.text('左右分屏'), findsOneWidget);
      expect(find.text('上下分屏'), findsOneWidget);
      expect(find.text('关掉此分屏'), findsNothing); // 首屏文案带 AI 提示
      expect(find.textContaining('关掉此分屏'), findsOneWidget);
    });

    testWidgets('首屏的关闭项标危险色并写明 AI 绑定', (tester) async {
      await pump(tester, terminal: readyTerminal(), panes: actions());
      await rightClick(tester, const Offset(30, 10));
      expect(find.textContaining('AI 在这屏'), findsOneWidget);
    });

    testWidgets('已达上限：分屏项禁用，点它什么都不发', (tester) async {
      await pump(tester,
          terminal: readyTerminal(), panes: actions(canSplit: false));
      await rightClick(tester, const Offset(30, 10));
      await tester.tap(find.text('左右分屏'));
      await tester.pumpAndSettle();
      expect(log.where((e) => e.startsWith('split:')), isEmpty);
    });

    testWidgets('未分屏时不出「关掉此分屏」项', (tester) async {
      await pump(tester,
          terminal: readyTerminal(), panes: actions(isSplit: false));
      await rightClick(tester, const Offset(30, 10));
      expect(find.textContaining('关掉此分屏'), findsNothing);
    });
  });

  group('键表默认值', () {
    test('分屏默认组合都带修饰，且不用 Alt（Windows 上 AltGr 会劫持输入）', () {
      final map = TerminalKeymap.fromSettings(null);
      for (final action in [
        TerminalKeyAction.splitVertical,
        TerminalKeyAction.splitHorizontal,
        TerminalKeyAction.closePane,
        TerminalKeyAction.focusNextPane,
        TerminalKeyAction.focusPrevPane,
      ]) {
        final bindings = map.bindingsFor(action);
        expect(bindings, isNotEmpty, reason: '${action.id} 没有默认键');
        for (final b in bindings) {
          expect(b.hasModifier, isTrue, reason: '${b.serialized} 是裸键');
          expect(b.alt, isFalse, reason: '${b.serialized} 用了 Alt');
        }
      }
    });

    test('分屏键与既有动作不撞车', () {
      final seen = <String, TerminalKeyAction>{};
      for (final entry in kDefaultTerminalKeybindings.entries) {
        for (final b in entry.value) {
          expect(seen[b.serialized], isNull,
              reason:
                  '${b.serialized} 同属 ${seen[b.serialized]?.id} 和 ${entry.key.id}');
          seen[b.serialized] = entry.key;
        }
      }
    });

    testWidgets('shell 的 Ctrl+D（EOF）没有被分屏键抢走', (tester) async {
      await pump(tester, terminal: readyTerminal(), panes: actions());
      log.clear();
      await press(tester, LogicalKeyboardKey.keyD, ctrl: true);
      expect(log, isEmpty);
      expect(toShell.toString(), contains(String.fromCharCode(4)));
    });
  });
}
