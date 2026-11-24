import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/utils/terminal_blocks.dart';
import 'package:ai_terminal/widgets/terminal_context_menu.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

const String esc = '\x1B';
const String bel = '\x07';

String osc133(String body) => '$esc]133;$body$bel';

/// 终端 + 跟踪器一起造：跟踪器挂到 onPrivateOSC，与页面接线方式一致。
({xterm.Terminal terminal, TerminalBlockTracker tracker}) harness(
    List<({String cmd, String out, int exit})> blocks) {
  final terminal = xterm.Terminal(maxLines: 500);
  final tracker = TerminalBlockTracker(terminal: terminal);
  terminal.onPrivateOSC = tracker.onPrivateOsc;
  for (final b in blocks) {
    terminal.write(osc133('A'));
    terminal.write('user@web1:~\$ ${b.cmd}');
    terminal.write(osc133('B'));
    terminal.write('\r\n');
    terminal.write(osc133('C'));
    terminal.write('${b.out}\r\n');
    terminal.write(osc133('D;${b.exit}'));
    terminal.write('\r\n');
  }
  return (terminal: terminal, tracker: tracker);
}

Future<TestGesture> rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.addPointer(location: at);
  await gesture.down(at);
  await tester.pumpAndSettle();
  return gesture;
}

Future<void> pumpTerminal(
  WidgetTester tester,
  xterm.Terminal terminal,
  TerminalBlockTracker? tracker,
  void Function(TerminalMenuIntent, String)? onIntent,
) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: TerminalView(
          terminal: terminal,
          blockTracker: tracker,
          onMenuIntent: onIntent == null
              ? null
              : (intent, text) async => onIntent(intent, text),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('没装 shell 集成：菜单里完全不出现命令块项', (tester) async {
    final terminal = xterm.Terminal()..write('user@web1:~\$ ls\r\nfile\r\n');
    await pumpTerminal(
        tester, terminal, TerminalBlockTracker(terminal: terminal), (_, __) {});

    final gesture = await rightClick(tester, const Offset(30, 10));
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(find.text('让 Agent 解释这一整块'), findsNothing);
    expect(find.text('上一块命令'), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('有 OSC 133：右键块内出现「解释这一整块 / 上一块 / 下一块」', (tester) async {
    final h = harness([
      (cmd: 'df -h', out: '/dev/sda1 50G 30G 60%', exit: 0),
      (cmd: 'uptime', out: 'load average: 0.10', exit: 0),
    ]);
    await pumpTerminal(tester, h.terminal, h.tracker, (_, __) {});

    final gesture = await rightClick(tester, const Offset(30, 10));
    expect(find.text('让 Agent 解释这一整块'), findsOneWidget);
    expect(find.text('复制这一整块'), findsOneWidget);
    expect(find.text('上一块命令'), findsOneWidget);
    expect(find.text('下一块命令'), findsOneWidget);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('解释这一整块：把命令与输出一起交给页面', (tester) async {
    final captured = <({TerminalMenuIntent intent, String text})>[];
    final h = harness([
      (cmd: 'systemctl status nginx', out: 'Active: failed', exit: 3),
      (cmd: 'journalctl -u nginx', out: 'Permission denied', exit: 1),
    ]);
    await pumpTerminal(tester, h.terminal, h.tracker,
        (i, t) => captured.add((intent: i, text: t)));

    final gesture = await rightClick(tester, const Offset(30, 10));
    await tester.tap(find.text('让 Agent 解释这一整块'));
    await tester.pumpAndSettle();

    expect(captured, hasLength(1));
    expect(captured.single.intent, TerminalMenuIntent.askBlock);
    expect(captured.single.text, contains('systemctl status nginx'));
    expect(captured.single.text, contains('Active: failed'));
    // 第二块的输出不能混进来
    expect(captured.single.text.contains('journalctl'), isFalse);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('最后一块：「下一块」禁用，点它什么都不发', (tester) async {
    final captured = <TerminalMenuIntent>[];
    final h = harness([
      (cmd: 'first', out: 'o1', exit: 0),
      (cmd: 'last', out: 'o2', exit: 0),
    ]);
    await pumpTerminal(
        tester, h.terminal, h.tracker, (i, _) => captured.add(i));

    // 右键第二块所在行：它前面有块、后面没有
    const lineHeight = 600 / 24;
    final secondLine = h.tracker.blocks[1].startLine!;
    final gesture =
        await rightClick(tester, Offset(30, (secondLine + 0.5) * lineHeight));
    expect(find.text('下一块命令'), findsOneWidget);
    expect(find.text('上一块命令'), findsOneWidget);
    // 边界：「下一块」是禁用项，点它不该有任何动作，也不该抛异常
    await tester.tap(find.text('下一块命令'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(captured, isEmpty);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('tracker 为空(null) 时不崩，仍可正常打开菜单', (tester) async {
    final terminal = xterm.Terminal()..write(osc133('A'));
    await pumpTerminal(tester, terminal, null, (_, __) {});
    final gesture = await rightClick(tester, const Offset(30, 10));
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('让 Agent 解释这一整块'), findsNothing);
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}
