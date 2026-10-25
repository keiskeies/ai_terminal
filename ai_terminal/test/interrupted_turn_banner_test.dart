import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/interrupted_turn_banner.dart';

void main() {
  testWidgets('shows interrupted state and invokes continue', (tester) async {
    var continued = false;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          return InterruptedTurnBanner(
            tc: ThemeColors.of(context),
            goal: '部署 Nginx',
            onContinue: () => continued = true,
          );
        }),
      ),
    ));

    expect(find.text('任务已中断'), findsOneWidget);
    expect(find.text('部署 Nginx'), findsOneWidget);
    expect(find.text('继续任务'), findsOneWidget);

    await tester.tap(find.text('继续任务'));
    expect(continued, isTrue);
  });

  testWidgets('hides continue button when no callback', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          return InterruptedTurnBanner(
            tc: ThemeColors.of(context),
          );
        }),
      ),
    ));

    expect(find.text('任务已中断'), findsOneWidget);
    expect(find.text('继续任务'), findsNothing);
  });
}
