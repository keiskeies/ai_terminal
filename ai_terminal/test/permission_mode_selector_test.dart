import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/constants.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/widgets/ai_prompt_input.dart';
import 'package:ai_terminal/widgets/permission_mode_selector.dart';

void main() {
  testWidgets('360px 窄屏底部工具行不溢出，权限胶囊仍可见', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: AIPromptInput(
            enabled: true,
            hintText: '输入目标',
            onSend: (_) {},
            accentColor: cBrand,
            permissionMode: AgentPermissionMode.ask,
            onPermissionModeChanged: (_) {},
            // 模拟最宽情况下的模型胶囊
            footer: const SizedBox(width: 170, height: 24),
          ),
        ),
      ),
    ));

    expect(find.byType(PermissionModeSelector), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单列出四档，选择全自动会回调', (tester) async {
    AgentPermissionMode? picked;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: AIPromptInput(
            enabled: true,
            hintText: '输入目标',
            onSend: (_) {},
            accentColor: cBrand,
            permissionMode: AgentPermissionMode.ask,
            onPermissionModeChanged: (mode) => picked = mode,
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(PermissionModeSelector));
    await tester.pumpAndSettle();

    expect(find.text('Read-only'), findsOneWidget);
    expect(find.text('Ask'), findsWidgets);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Full auto'), findsOneWidget);

    await tester.tap(find.text('Full auto'));
    await tester.pumpAndSettle();
    expect(picked, AgentPermissionMode.fullAuto);
  });
}
