import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/reconnecting_banner.dart';

void main() {
  testWidgets('shows reconnecting host and phase', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          return ReconnectingBanner(
            tc: ThemeColors.of(context),
            hostLabel: 'web-01',
          );
        }),
      ),
    ));

    expect(find.textContaining('正在重连 web-01'), findsOneWidget);
    expect(find.textContaining('连接恢复中'), findsOneWidget);
  });
}
