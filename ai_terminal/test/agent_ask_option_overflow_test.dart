import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/agent_ask_card.dart';

/// 布局回归：询问卡的选项胶囊（[AgentAskOptionChip]）在超长选项下不溢出。
///
/// 选项文案是模型给的，长度没有上限。真机上出现过一条候选把三个选项挤进
/// 同一行的情况——`Wrap` 给子项的是无限宽约束，胶囊内部的 `Row` 按文本固有
/// 宽度排版，直接顶穿面板并刷出「RenderFlex overflowed by 414 pixels」。
void main() {
  const longOption = '["ncdu — disk usage analyzer", "nload — live network '
      'bandwidth monitor", "iotop — per-process disk I/O", "bmon — bandwidth '
      'monitor and shaper"]';

  /// 复刻询问卡里的选项排布：`Wrap` + 限宽 `ConstrainedBox` + 胶囊。
  Widget optionRow(String label, double width) => Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: Builder(
            builder: (context) {
              final tc = ThemeColors.of(context);
              return LayoutBuilder(
                builder: (context, c) {
                  final cap = (c.maxWidth.isFinite ? c.maxWidth : 320.0) * 0.92;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [label, label]
                        .map((opt) => ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: cap),
                              child: AgentAskOptionChip(
                                label: opt,
                                tc: tc,
                                selectable: true,
                                onTap: (_) {},
                              ),
                            ))
                        .toList(),
                  );
                },
              );
            },
          ),
        ),
      );

  Future<void> host(WidgetTester tester, Widget child) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: MaterialApp(home: Scaffold(body: child)),
          ),
        ),
      );

  for (final width in const [320.0, 900.0]) {
    testWidgets('长选项在 ${width.toInt()}px 面板里换行而不是溢出', (tester) async {
      await host(tester, optionRow(longOption, width));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: '长选项在 ${width.toInt()}px 宽的面板里溢出');
    });
  }

  testWidgets('短选项仍是单行胶囊', (tester) async {
    await host(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 320,
          child: Builder(
            builder: (context) => AgentAskOptionChip(
              label: '确认执行计划',
              tc: ThemeColors.of(context),
              selectable: true,
              onTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认执行计划'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
