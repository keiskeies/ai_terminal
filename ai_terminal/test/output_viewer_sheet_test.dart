import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/theme_colors.dart';
import 'package:ai_terminal/widgets/output_viewer_sheet.dart';

void main() {
  testWidgets('filters output by search query', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          return OutputViewerSheet(
            text: 'line one\nline two\nERROR something failed',
            tc: ThemeColors.of(context),
            title: '原始输出尾部',
          );
        }),
      ),
    ));

    expect(find.text('原始输出尾部'), findsOneWidget);
    expect(find.textContaining('line one'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'error');
    await tester.pump();

    expect(find.textContaining('ERROR something failed'), findsOneWidget);
    expect(find.textContaining('line one'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    expect(find.text('没有匹配内容'), findsOneWidget);
  });
}
