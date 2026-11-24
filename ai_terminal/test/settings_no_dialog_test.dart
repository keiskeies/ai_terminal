import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:ai_terminal/services/mcp_manager.dart';
import 'package:ai_terminal/services/mcp_models.dart';
import 'package:ai_terminal/widgets/nav_drawer.dart';

/// 设置只有一个载体：右侧抽屉。
///
/// 这一组测试把「不许再弹对话框」钉死：点加端点、加 MCP 服务器、加规范、
/// 改语言，全部必须留在抽屉里，屏幕上不能出现 AlertDialog / Dialog。
void main() {
  setUp(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  tearDown(() {
    McpManager.instance.loadConfigsForTesting([]);
  });

  Future<void> pumpDrawer(WidgetTester tester) async {
    // 抽屉里的内容比一屏长，放大窗口免去滚动（滚动手势会和抽屉关闭抢）。
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NavDrawer(
            section: NavDrawer.sectionSettings,
            onOpenHost: (_) {},
            onRunSnippet: (_) {},
            onRunRunbook: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// 展开某一组（八组都折叠时，组标题就是入口）
  Future<void> expandGroup(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  void expectNoDialog() {
    expect(find.byType(AlertDialog), findsNothing,
        reason: '设置里不允许再弹 AlertDialog');
    expect(find.byType(Dialog), findsNothing, reason: '设置里不允许再弹 Dialog');
    expect(find.byType(SimpleDialog), findsNothing,
        reason: '设置里不允许再弹 SimpleDialog');
  }

  testWidgets('加端点留在抽屉里，不弹对话框', (tester) async {
    await pumpDrawer(tester);
    await expandGroup(tester, 'AI 模型');

    expectNoDialog();
    await tester.tap(find.text('添加端点'));
    await tester.pumpAndSettle();

    expectNoDialog();
    // 表单换在抽屉内：有「返回」，也有端点才有的字段。
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('服务商'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
  });

  testWidgets('加 MCP 服务器留在抽屉里，不弹对话框', (tester) async {
    await pumpDrawer(tester);
    await expandGroup(tester, 'MCP 服务器');

    await tester.tap(find.text('添加服务器'));
    await tester.pumpAndSettle();

    expectNoDialog();
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('传输方式'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);

    // 返回后回到 MCP 组列表，抽屉还在
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('添加服务器'), findsOneWidget);
  });

  testWidgets('加规范留在抽屉里，不弹对话框', (tester) async {
    await pumpDrawer(tester);
    await expandGroup(tester, '内部规范');

    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();

    expectNoDialog();
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('规范内容'), findsOneWidget);
    expect(find.text('作用域'), findsOneWidget);
  });

  testWidgets('改语言是就地展开一列，不弹对话框', (tester) async {
    await pumpDrawer(tester);

    await tester.tap(find.text('语言'));
    await tester.pumpAndSettle();

    expectNoDialog();
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('删 MCP 服务器是就地确认条，不弹对话框', (tester) async {
    McpManager.instance.loadConfigsForTesting(const [
      McpServerConfig(id: 'fake', name: 'Fake', enabled: true),
    ]);
    await pumpDrawer(tester);
    await expandGroup(tester, 'MCP 服务器');

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expectNoDialog();
    // 确认条就长在那一行上，带条目名和「取消 / 确认」。
    expect(find.textContaining('删除「Fake」'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);

    // 取消后回到正常行，没有真删。
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.textContaining('删除「Fake」'), findsNothing);
    expect(find.text('Fake'), findsOneWidget);
  });
}
