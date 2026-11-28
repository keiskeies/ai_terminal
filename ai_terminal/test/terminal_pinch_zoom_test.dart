import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/widgets/terminal_view.dart';

/// 端到端宿主：真实持有字号状态，捏合经 onFontSizeChanged 回写后重建终端，
/// 用来验证「回调 → 页面 setState → 渲染字号」整条链路，而不只是回调被调用。
class _FontSizedHost extends StatefulWidget {
  const _FontSizedHost({required this.term});

  final xterm.Terminal term;

  @override
  State<_FontSizedHost> createState() => _FontSizedHostState();
}

class _FontSizedHostState extends State<_FontSizedHost> {
  double _fontSize = 14;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: TerminalView(
            terminal: widget.term,
            fontSize: _fontSize,
            pinchZoomEnabledForTesting: true,
            onFontSizeChanged: (size) =>
                setState(() => _fontSize = size.clamp(10.0, 24.0)),
          ),
        ),
      ),
    );
  }
}

/// 在 [TerminalView] 上做多指手势。
///
/// `tester.startGesture` 每次只带一根手指，双指捏合要通过 TestGesture 按 pointer
/// 分别下发 down/move/up，才能让手势竞技看到两根并存的指针。
Future<void> _pumpTerminal(
  WidgetTester tester, {
  required ValueChanged<double> onFontSizeChanged,
  bool? pinchEnabled,
  double fontSize = 14,
}) async {
  final term = xterm.Terminal(maxLines: 200);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.darkTheme,
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: TerminalView(
          terminal: term,
          fontSize: fontSize,
          onFontSizeChanged: onFontSizeChanged,
          pinchZoomEnabledForTesting: pinchEnabled,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('双指张开会放大字号（回调收到更大的字号）', (tester) async {
    final sizes = <double>[];
    await _pumpTerminal(tester,
        onFontSizeChanged: sizes.add, pinchEnabled: true);

    final center = tester.getCenter(find.byType(TerminalView));
    final g1 = await tester.startGesture(center - const Offset(30, 0),
        pointer: 1);
    final g2 = await tester.startGesture(center + const Offset(30, 0),
        pointer: 2);
    await tester.pump();

    // 两指各向外拉开 80px：跨度从 60 → 220，约 3.6 倍 ≈ +2 个台阶。
    await g1.moveBy(const Offset(-80, 0));
    await g2.moveBy(const Offset(80, 0));
    await tester.pump();

    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    expect(sizes, isNotEmpty, reason: '捏合应触发字号回调');
    expect(sizes.last, greaterThan(14), reason: '张开应放大字号');
  });

  testWidgets('双指捏合会缩小字号', (tester) async {
    final sizes = <double>[];
    await _pumpTerminal(tester,
        onFontSizeChanged: sizes.add, pinchEnabled: true);

    final center = tester.getCenter(find.byType(TerminalView));
    final g1 = await tester.startGesture(center - const Offset(120, 0),
        pointer: 1);
    final g2 = await tester.startGesture(center + const Offset(120, 0),
        pointer: 2);
    await tester.pump();

    // 跨度从 240 → 60，缩小到 1/4 ≈ -2 个台阶。
    await g1.moveBy(const Offset(90, 0));
    await g2.moveBy(const Offset(-90, 0));
    await tester.pump();

    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    expect(sizes, isNotEmpty, reason: '捏合应触发字号回调');
    expect(sizes.last, lessThan(14), reason: '捏合应缩小字号');
  });

  testWidgets('单指拖动不触发缩放（不能抢走滚动/选择）', (tester) async {
    final sizes = <double>[];
    await _pumpTerminal(tester,
        onFontSizeChanged: sizes.add, pinchEnabled: true);

    final center = tester.getCenter(find.byType(TerminalView));
    final g = await tester.startGesture(center, pointer: 1);
    await tester.pump();
    await g.moveBy(const Offset(0, -200));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(sizes, isEmpty, reason: '单指纵向拖动是滚动，不该改字号');
  });

  testWidgets('关闭缩放时双指捏合不触发回调', (tester) async {
    final sizes = <double>[];
    await _pumpTerminal(tester,
        onFontSizeChanged: sizes.add, pinchEnabled: false);

    final center = tester.getCenter(find.byType(TerminalView));
    final g1 = await tester.startGesture(center - const Offset(30, 0),
        pointer: 1);
    final g2 = await tester.startGesture(center + const Offset(30, 0),
        pointer: 2);
    await tester.pump();
    await g1.moveBy(const Offset(-80, 0));
    await g2.moveBy(const Offset(80, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    expect(sizes, isEmpty, reason: '禁用后不应有任何字号回调');
  });

  testWidgets('端到端：捏合后终端真正以更大字号渲染', (tester) async {
    final term = xterm.Terminal(maxLines: 200);
    await tester.pumpWidget(_FontSizedHost(term: term));
    await tester.pumpAndSettle();

    double currentFontSize() =>
        tester.widget<TerminalView>(find.byType(TerminalView)).fontSize;

    expect(currentFontSize(), 14.0);

    final center = tester.getCenter(find.byType(TerminalView));
    final g1 = await tester.startGesture(center - const Offset(30, 0),
        pointer: 1);
    final g2 = await tester.startGesture(center + const Offset(30, 0),
        pointer: 2);
    await tester.pump();
    await g1.moveBy(const Offset(-90, 0));
    await g2.moveBy(const Offset(90, 0));
    await tester.pumpAndSettle();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    expect(currentFontSize(), greaterThan(14.0),
        reason: '宿主 setState 后 TerminalView.fontSize 应变大');
  });
}