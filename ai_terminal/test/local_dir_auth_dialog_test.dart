import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ai_terminal/widgets/local_dir_auth_dialog.dart';

void main() {
  final missingPath =
      p.join(Directory.systemTemp.path, 'ai_terminal_auth_test_missing_dir');

  Future<bool?> pumpAndOpen(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showLocalDirAuthDialog(
                context,
                path: missingPath,
                reason: 'local_exec 需要在该目录执行本机命令：docker save',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('展示路径、创建提示与敏感路径说明', (tester) async {
    await pumpAndOpen(tester);

    expect(find.text('Allow local folder access?'), findsOneWidget);
    expect(find.textContaining(missingPath), findsOneWidget);
    expect(find.textContaining('will be created'), findsOneWidget);
    expect(find.textContaining('Sensitive paths'), findsOneWidget);
    expect(find.text('Allow and continue'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('允许返回 true', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showLocalDirAuthDialog(
                context,
                path: missingPath,
                reason: 'local_exec 需要在该目录执行本机命令',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow and continue'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('取消返回 false', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showLocalDirAuthDialog(
                context,
                path: missingPath,
                reason: 'local_exec 需要在该目录执行本机命令',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
