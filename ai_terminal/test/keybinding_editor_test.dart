import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/terminal_keybindings.dart';
import 'package:ai_terminal/core/theme.dart';
import 'package:ai_terminal/widgets/keybinding_editor.dart';

/// 编辑面板只做「读表 + 调纯函数」，规则本身在 terminal_keybindings_test.dart。
/// 这里验接线：动作列得全、点删除真的把新覆盖表交出去、
/// 「恢复默认」只出现在改过的那一行。
void main() {
  final isMac = Platform.isMacOS;

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Map<String, List<String>> overrides,
    ValueChanged<Map<String, List<String>>>? onChanged,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 1200,
          child: SingleChildScrollView(
            child: KeybindingEditorPanel(
              overrides: overrides,
              onChanged: onChanged ?? (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('每个可重绑动作都列出标签与生效组合', (tester) async {
    await pumpPanel(tester, overrides: const {});
    for (final action in TerminalKeyAction.values) {
      expect(find.text(action.label(isZh: true)), findsOneWidget);
    }
    // 搜索的默认组合（按平台取文案）要在场
    final searchLabel = kDefaultTerminalKeybindings[TerminalKeyAction.search]!
        .firstWhere((b) => isMac ? b.meta : b.ctrl)
        .label(isMac: isMac);
    expect(find.text(searchLabel), findsOneWidget);
  });

  testWidgets('点某条组合的关闭图标 → 提交去掉它之后的覆盖表', (tester) async {
    const search = TerminalKeyAction.search;
    final extra = parseKeyBinding('alt+f9')!;
    final overrides = addBinding(const {}, search, extra);
    Map<String, List<String>>? saved;
    await pumpPanel(
      tester,
      overrides: overrides,
      onChanged: (next) => saved = next,
    );

    expect(find.text(extra.label(isMac: isMac)), findsOneWidget);
    // chip 的关闭图标在它自己的 InkWell 里；页面上有多颗关闭图标，
    // 取文案紧邻的那一颗
    final chip = find.ancestor(
      of: find.text(extra.label(isMac: isMac)),
      matching: find.byType(InkWell),
    );
    await tester
        .tap(find.descendant(of: chip, matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(effectiveBindingStrings(saved!, search),
        isNot(contains(extra.serialized)));
    // 默认那几条仍然留着（删一条不该把整个动作清空）
    expect(
      effectiveBindingStrings(saved!, search),
      containsAll(
          kDefaultTerminalKeybindings[search]!.map((b) => b.serialized)),
    );
  });

  testWidgets('「恢复默认」只出现在改过的那个动作那一行', (tester) async {
    final overrides = addBinding(
        const {}, TerminalKeyAction.zoomIn, parseKeyBinding('alt+f8')!);
    await pumpPanel(tester, overrides: overrides);
    expect(find.text('恢复默认'), findsOneWidget);
  });

  testWidgets('全默认时一颗「恢复默认」都没有', (tester) async {
    await pumpPanel(tester, overrides: const {});
    expect(find.text('恢复默认'), findsNothing);
  });
}
