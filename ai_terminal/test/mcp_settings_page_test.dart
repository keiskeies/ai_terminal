import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/pages/mcp_settings_page.dart';
import 'package:ai_terminal/services/mcp_manager.dart';

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

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.text('添加 MCP 服务器'), findsOneWidget);
    expect(find.text('保存并连接'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('还没有 MCP 服务器'), findsOneWidget);
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
