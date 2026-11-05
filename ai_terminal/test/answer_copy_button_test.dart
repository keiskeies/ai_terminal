import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 terminal_page 里「复制回答」胶囊的层级与状态：
/// SelectionArea → ListView → (Align → Container → Column) → MouseRegion
/// + GestureDetector(opaque) + AnimatedContainer，点击后按钮自己变「已复制」。
/// 之前真机上它既没有手型光标也没有点按反馈，这里把三件事都钉住。
class _CopyPill extends StatefulWidget {
  const _CopyPill({
    required this.onTap,
    required this.label,
    required this.doneLabel,
  });

  final VoidCallback onTap;
  final String label;
  final String doneLabel;

  @override
  State<_CopyPill> createState() => _CopyPillState();
}

class _CopyPillState extends State<_CopyPill> {
  bool _hover = false;
  bool _copied = false;
  Timer? _doneTimer;

  void _copy() {
    widget.onTap();
    setState(() => _copied = true);
    _doneTimer?.cancel();
    _doneTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _doneTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _copy,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: _copied
                  ? Colors.green.withValues(alpha: 0.12)
                  : _hover
                      ? Colors.blue.withValues(alpha: 0.07)
                      : Colors.transparent,
              border: Border.all(
                color: _copied
                    ? Colors.green
                    : _hover
                        ? Colors.blue
                        : Colors.grey,
                width: 0.5,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _copied ? Icons.check_rounded : Icons.copy_all_outlined,
                  size: 12,
                  color: _hover ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 5),
                Text(_copied ? widget.doneLabel : widget.label,
                    style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  Future<void> pump(WidgetTester tester, {required VoidCallback onTap}) async {
    await tester.pumpWidget(MaterialApp(
      home: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('一段可以被选中的回答正文，用来确认外层确实是选择容器。'),
            ),
            _CopyPill(onTap: onTap, label: '复制回答', doneLabel: '已复制'),
          ],
        ),
      ),
    ));
  }

  BoxDecoration deco(WidgetTester tester) => tester
      .widget<AnimatedContainer>(find.descendant(
        of: find.byType(_CopyPill),
        matching: find.byType(AnimatedContainer),
      ))
      .decoration as BoxDecoration;

  testWidgets('SelectionArea 里的复制胶囊点得中', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);

    await tester.tap(find.text('复制回答'));
    await tester.pump();
    expect(taps, 1, reason: '点在标签文字上没有触发 onTap');

    // 胶囊内空白处（图标左侧的 padding 区域）也要能点
    final box = tester.getRect(find.byType(_CopyPill));
    await tester.tapAt(Offset(box.left + 3, box.center.dy));
    await tester.pump();
    expect(taps, 2, reason: '点在胶囊内空白处没有触发 onTap');
  });

  testWidgets('胶囊自己声明了手型光标', (tester) async {
    await pump(tester, onTap: () {});

    final regions = tester
        .widgetList<MouseRegion>(find.descendant(
          of: find.byType(_CopyPill),
          matching: find.byType(MouseRegion),
        ))
        .toList();
    expect(regions.any((r) => r.cursor == SystemMouseCursors.click), isTrue);
  });

  testWidgets('悬停有描边反馈，点击后按钮自己变「已复制」再回位', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);

    final center = tester.getRect(find.byType(_CopyPill)).center;
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(deco(tester).border!.top.color, Colors.grey);

    // 悬停：描边变强调色
    await pointer.moveTo(center);
    await tester.pumpAndSettle();
    expect(deco(tester).border!.top.color, Colors.blue);

    // 点击：文案与图标切成已复制态（按下态受手势竞争影响，不作为判据）
    await pointer.down(center);
    await pointer.up();
    await tester.pump();
    expect(taps, 1);
    expect(find.text('已复制'), findsOneWidget);
    expect(find.text('复制回答'), findsNothing);
    expect(deco(tester).border!.top.color, Colors.green);

    // 回执是暂时的，不能把按钮永久留在已复制态
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.text('复制回答'), findsOneWidget);
    expect(find.text('已复制'), findsNothing);
  });

  testWidgets('气泡层级里（Align+Container+Column）也点得中', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: SelectionArea(
        child: ListView(
          children: [
            // 复刻 _buildMessageBubble 的祖先链：Align → Container(约束/边距/装饰) → Column
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 500),
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blueGrey),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI 助手'),
                    const Text('回答正文一段。'),
                    _CopyPill(
                        onTap: () => taps++,
                        label: '复制回答',
                        doneLabel: '已复制'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    final box = tester.getRect(find.byType(_CopyPill));
    await tester.tapAt(box.center);
    await tester.pump();
    expect(taps, 1,
        reason: '气泡内最后一个子节点点不中，说明被祖先或兄弟节点挡住了');
  });
}
