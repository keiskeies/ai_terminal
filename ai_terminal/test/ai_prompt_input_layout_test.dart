import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/constants.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/widgets/ai_prompt_input.dart';

void main() {
  Future<void> pumpInput(WidgetTester tester, {bool isOrch = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: AIPromptInput(
            enabled: true,
            hintText: '描述需求',
            isOrchestratorMode: isOrch,
            onSend: (_) {},
            accentColor: cBrand,
            permissionMode: AgentPermissionMode.ask,
            onPermissionModeChanged: (_) {},
          ),
        ),
      ),
    ));
  }

  testWidgets('多机编排开关不再挤在输入框里', (tester) async {
    await pumpInput(tester, isOrch: true);

    expect(find.byIcon(Icons.hub_outlined), findsNothing);
    // 编排模式下输入框仍保留警示描边
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入框默认两行高，最多仍到五行', (tester) async {
    await pumpInput(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 2);
    expect(field.maxLines, 5);
  });
}
