import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

void main() {
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

  testWidgets('右键 URL 行：菜单含「打开链接」', (tester) async {
    final terminal = xterm.Terminal()..write('https://example.com\n');
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

    final gesture = await rightClick(tester, const Offset(30, 10));
    expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget,
        reason: '右键 URL 行应出现打开链接项');
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
  });
}