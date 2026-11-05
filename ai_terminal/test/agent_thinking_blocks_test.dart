import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/agent_thinking_blocks.dart';

void main() {
  Future<void> pump(
      WidgetTester tester, Widget Function(ThemeColors tc) build) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: Builder(builder: (ctx) => build(ThemeColors.of(ctx)))),
    ));
  }

  group('ModelReasoningBlock', () {
    testWidgets('渲染推理正文，并限制在 160 高度内', (tester) async {
      await pump(tester,
          (tc) => ModelReasoningBlock(text: '先确认磁盘占用，再看服务', tc: tc));

      expect(find.text('模型思考'), findsOneWidget);
      expect(find.text('先确认磁盘占用，再看服务'), findsOneWidget);

      final box = tester.widget<ConstrainedBox>(find.descendant(
        of: find.byType(ModelReasoningBlock),
        matching: find.byType(ConstrainedBox),
      ));
      expect(box.constraints.maxHeight, 160);
    });
  });

  group('LiveThoughtBlock', () {
    testWidgets('只显示思考正文，协议行不进入界面', (tester) async {
      await pump(
          tester,
          (tc) => LiveThoughtBlock(
                rawText: '思考: 先看看系统版本\n动作: execute\n命令: uname -a',
                tc: tc,
              ));

      expect(find.text('思考中'), findsOneWidget);
      expect(find.text('先看看系统版本'), findsOneWidget);
      expect(find.textContaining('动作:'), findsNothing);
      expect(find.textContaining('命令:'), findsNothing);
    });

    testWidgets('思考还没写内容时不占位', (tester) async {
      await pump(tester,
          (tc) => LiveThoughtBlock(rawText: '思考: \n动作: execute', tc: tc));

      expect(find.text('思考中'), findsNothing);
    });

    testWidgets('拿不到协议头时按纯文本显示（非 ReAct 模型）', (tester) async {
      await pump(tester,
          (tc) => LiveThoughtBlock(rawText: '正在检查磁盘使用率…', tc: tc));

      expect(find.text('正在检查磁盘使用率…'), findsOneWidget);
    });
  });
}
