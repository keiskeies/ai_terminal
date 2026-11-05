import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 terminal_page 里「复制回答」胶囊的层级：
/// SelectionArea → ListView → MouseRegion + GestureDetector(opaque) + AnimatedContainer。
/// 之前真机上点了没反应，先确认这个结构在 SelectionArea 里到底能不能点中。
class _CopyPill extends StatefulWidget {
  const _CopyPill({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  State<_CopyPill> createState() => _CopyPillState();
}

class _CopyPillState extends State<_CopyPill> {
  bool _hover = false;
  bool _pressed = false;

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
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey, width: 0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.copy_all_outlined, size: 12),
                const SizedBox(width: 5),
                Text(widget.label,
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
  testWidgets('SelectionArea 里的复制胶囊点得中', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: SelectionArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('一段可以被选中的回答正文，用来确认外层确实是选择容器。'),
            ),
            _CopyPill(onTap: () => taps++, label: '复制回答'),
          ],
        ),
      ),
    ));

    // 点在文字上
    await tester.tap(find.text('复制回答'));
    await tester.pump();
    expect(taps, 1, reason: '点在标签文字上没有触发 onTap');

    // 点在胶囊空白处（图标与文字之外的 padding 区域）
    final pill = find.byType(_CopyPill);
    final box = tester.getRect(pill);
    await tester.tapAt(Offset(box.left + 3, box.center.dy));
    await tester.pump();
    expect(taps, 2, reason: '点在胶囊内空白处没有触发 onTap');
  });

  testWidgets('胶囊自己声明了手型光标', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: SelectionArea(
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('一段可以被选中的回答正文。'),
            ),
            _CopyPill(onTap: () {}, label: '复制回答'),
          ],
        ),
      ),
    ));

    final regions = tester
        .widgetList<MouseRegion>(find.descendant(
          of: find.byType(_CopyPill),
          matching: find.byType(MouseRegion),
        ))
        .toList();
    expect(regions.any((r) => r.cursor == SystemMouseCursors.click), isTrue);
  });

  testWidgets('气泡层级里（Align+Container+Column）也点得中', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            // 复刻 _buildMessageBubble 的祖先链：Align → Container(约束/边距/装饰) → Column
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 500),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blueGrey),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI 助手'),
                    const Text('回答正文一段。'),
                    _CopyPill(onTap: () => taps++, label: '复制回答'),
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
    expect(taps, 1, reason: '气泡内最后一个子节点点不中，说明被祖先或兄弟节点挡住了');
  });
}
