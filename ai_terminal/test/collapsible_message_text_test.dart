import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/widgets/collapsible_message_text.dart';

const _longText = '请继续朝该目标推进。若你确认目标已经完全达成，只在回答正文里单独一行写目标已达成并说明结果；'
    '这一行是结论，不是命令，绝不能放进命令块或工具参数里。未达成则正常执行下一步，不要提前结束。'
    '另外请把每一步的验证证据一起贴出来，方便我复核。';

void main() {
  Future<void> pump(WidgetTester tester, String text) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: CollapsibleMessageText(
              text: text,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('两行以内的短消息不出现展开控件', (tester) async {
    await pump(tester, '检查一下磁盘占用');

    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(tester.widget<Text>(find.text('检查一下磁盘占用')).maxLines, isNull);
  });

  testWidgets('超长消息默认收起到两行，点展开后完整显示，再点收起', (tester) async {
    await pump(tester, _longText);

    final collapsed = tester.widget<Text>(find.text(_longText));
    expect(collapsed.maxLines, 2);
    expect(collapsed.overflow, TextOverflow.ellipsis);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();

    final expanded = tester.widget<Text>(find.text(_longText));
    expect(expanded.maxLines, isNull);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(_longText)).maxLines, 2);
  });
}
