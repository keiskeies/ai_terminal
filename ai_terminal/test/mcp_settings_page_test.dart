import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/pages/mcp_settings_page.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/services/mcp_models.dart';

void main() {
  setUp(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  tearDown(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  testWidgets('MCP 设置页空状态与快速添加', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const McpSettingsPage(),
      ),
    );
    await tester.pump();

    expect(find.text('MCP 服务器'), findsOneWidget);
    expect(find.text('还没有 MCP 服务器'), findsOneWidget);
    expect(find.text('Exa MCP'), findsOneWidget);
    expect(find.text('Parallel MCP'), findsOneWidget);
    expect(find.text('Filesystem'), findsOneWidget);
    expect(find.text('Context7'), findsOneWidget);
    expect(find.textContaining('启用 MCP（总开关）'), findsOneWidget);

    final globalSwitch = find.byType(Switch);
    expect(globalSwitch, findsOneWidget);
    expect(tester.widget<Switch>(globalSwitch).value, isTrue);
    await tester.tap(globalSwitch);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Switch>(globalSwitch).value, isFalse);
    await tester.tap(globalSwitch);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Switch>(globalSwitch).value, isTrue);

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('添加 MCP 服务器'), findsOneWidget);
    expect(find.text('保存并连接'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('还没有 MCP 服务器'), findsOneWidget);
  });

  testWidgets('工具状态使用 Agent 可用文案', (tester) async {
    McpManager.instance.loadConfigsForTesting([]);
    McpManager.instance.setRuntimeForTesting(const McpServerRuntime(
      config: McpServerConfig(
        id: 'fake',
        name: 'Fake',
        enabled: true,
        toolExposure: McpToolExposure.readOnly,
      ),
      status: McpServerStatus.connected,
      tools: [
        McpToolDescriptor(
          name: 'echo',
          title: 'echo',
          description: 'echo',
          inputSchema: {
            'type': 'object',
            'properties': {
              'message': {'type': 'string'},
            },
          },
          readOnly: true,
          destructive: false,
          idempotent: true,
          openWorld: false,
        ),
      ],
    ));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const McpSettingsPage(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Agent 可用 1 个工具'), findsOneWidget);
    await tester.tap(find.text('工具与能力'));
    await tester.pumpAndSettle();
    expect(find.text('Agent 可用'), findsOneWidget);
    expect(find.text('已暴露'), findsNothing);
    expect(find.text('未暴露'), findsNothing);
  });

  testWidgets('MCP 设置页 360px 窄屏不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const McpSettingsPage(),
      ),
    );
    await tester.pump();

    expect(find.text('还没有 MCP 服务器'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);
  });
}
