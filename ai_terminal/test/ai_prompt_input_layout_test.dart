import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/constants.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/widgets/ai_prompt_input.dart';

void main() {
  Future<void> pumpInput(
    WidgetTester tester, {
    bool isOrch = false,
    List<SlashCommand> extras = const [],
    bool Function(String)? onSlashCommand,
    void Function(String)? onSend,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 360,
            child: AIPromptInput(
              enabled: true,
              hintText: '描述需求',
              isOrchestratorMode: isOrch,
              onSend: onSend ?? (_) {},
              accentColor: cBrand,
              permissionMode: AgentPermissionMode.ask,
              onPermissionModeChanged: (_) {},
              slashExtras: extras,
              onSlashCommand: onSlashCommand,
            ),
          ),
        ),
      ),
    ));
  }

  Future<void> focusAndEnter(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
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
    // 左下角的字符计数已去掉
    expect(find.textContaining('/ 50000'), findsNothing);
    expect(find.textContaining('0 / '), findsNothing);
  });

  testWidgets('输入 / 立即弹出建议，宽度对齐输入框且位于输入框上方', (tester) async {
    await pumpInput(tester);
    await focusAndEnter(tester, '/');

    expect(find.byKey(kSlashOverlayKey), findsOneWidget);
    final inputRect = tester.getRect(find.byType(AIPromptInput));
    final overlayRect = tester.getRect(find.byKey(kSlashOverlayKey));
    // 回归：旧实现用 Overlay 的 RenderBox 测量，浮层会铺满整屏且被顶出屏幕。
    expect(overlayRect.width, closeTo(inputRect.width, 0.5));
    expect(overlayRect.bottom, lessThanOrEqualTo(inputRect.top + 0.5));
    expect(find.text('/new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('↑↓ 切换高亮，Tab 选中该命令', (tester) async {
    await pumpInput(tester, onSlashCommand: (_) => true);
    await focusAndEnter(tester, '/');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, '/compact');
    // 选中后继续写参数不应再次弹出建议
    expect(find.byKey(kSlashOverlayKey), findsNothing);
  });

  testWidgets('Enter 执行高亮命令，Esc 关闭浮层', (tester) async {
    final executed = <String>[];
    await pumpInput(tester, onSlashCommand: (c) {
      executed.add(c);
      return true;
    });
    await focusAndEnter(tester, '/');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(executed, ['/new']);
    expect(find.byKey(kSlashOverlayKey), findsNothing);

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.byKey(kSlashOverlayKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(kSlashOverlayKey), findsNothing);
  });

  testWidgets('鼠标点击建议项生效，不会因输入框失焦丢失点击', (tester) async {
    await pumpInput(tester, onSlashCommand: (_) => true);
    await focusAndEnter(tester, '/');

    await tester.tap(find.text('/compact'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '/compact',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('运维模板进入斜杠建议，Tab 选中后直接执行', (tester) async {
    var selected = false;
    await pumpInput(tester, extras: [
      SlashCommand(
        '/磁盘巡检',
        '检查磁盘使用率',
        isTemplate: true,
        leading: '📋',
        badge: 'AI',
        searchText: '磁盘巡检 检查磁盘使用率',
        onSelect: () => selected = true,
      ),
    ]);
    await focusAndEnter(tester, '/磁盘');

    expect(find.text('/磁盘巡检'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(selected, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, '');
    expect(find.byKey(kSlashOverlayKey), findsNothing);
  });
}
