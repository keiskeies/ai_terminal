import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/app_toast.dart';

void main() {
  testWidgets('顶部提示显示在顶部并在超时后消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showTopSnackBar(
                  context,
                  const SnackBar(
                    content: Text('顶部提示'),
                    duration: Duration(milliseconds: 300),
                  ),
                );
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('顶部提示'), findsOneWidget);
    expect(tester.getTopLeft(find.text('顶部提示')).dy, lessThan(100));

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('顶部提示'), findsNothing);
  });

  testWidgets('顶部提示 action 可点击并清除提示', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showTopSnackBar(
                  context,
                  SnackBar(
                    content: const Text('可撤销'),
                    duration: const Duration(seconds: 5),
                    action: SnackBarAction(
                      label: '撤销',
                      onPressed: () => tapped = true,
                    ),
                  ),
                );
              },
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('可撤销'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
    expect(find.text('可撤销'), findsNothing);
  });
}
