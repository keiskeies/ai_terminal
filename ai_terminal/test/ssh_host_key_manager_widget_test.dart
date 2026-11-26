import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/core/security/ssh_host_key_store.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/widgets/ssh_host_key_manager_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _knownHostsLine() {
  final type = utf8.encode('ssh-ed25519');
  final bytes = <int>[
    ...(ByteData(4)..setUint32(0, type.length)).buffer.asUint8List(),
    ...type,
    ...List<int>.filled(32, 7),
  ];
  return 'manager.example.com ssh-ed25519 ${base64.encode(bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SshHostKeyStore store;

  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await db.execute(sshHostKeysCreateSql);
    store = SshHostKeyStore(databaseOverride: db);
  });

  tearDown(() async => db.close());

  testWidgets('主机信任管理可预览、导入、导出并撤销', (tester) async {
    Future<void> settleDatabaseWork() async {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SshHostKeyManagerDialog(store: store),
            ),
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await settleDatabaseWork();
    expect(find.text('SSH 主机信任'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, _knownHostsLine());
    await tester.tap(find.text('预览'));
    await settleDatabaseWork();
    expect(find.text('manager.example.com · ssh-ed25519 · 新增'), findsOneWidget);

    await tester.tap(find.text('导入所选'));
    await settleDatabaseWork();
    final imported = await tester.runAsync(store.getAll);
    expect(imported, hasLength(1));
    expect(find.text('manager.example.com · ssh-ed25519 · 新增'), findsNothing);
    expect(find.text('manager.example.com · ssh-ed25519 · direct'),
        findsOneWidget);

    expect(find.byType(CheckboxListTile), findsOneWidget);
    final exportCheckbox = find.byType(CheckboxListTile).last;
    await tester.ensureVisible(exportCheckbox);
    if (tester.widget<CheckboxListTile>(exportCheckbox).value != true) {
      await tester.tap(exportCheckbox);
      await tester.pump();
    }
    expect(tester.widget<CheckboxListTile>(exportCheckbox).value, isTrue);
    await tester.ensureVisible(find.text('导出所选'));
    await tester.tap(find.text('导出所选'));
    await tester.pumpAndSettle();
    expect(find.text('导出 known_hosts'), findsOneWidget);
    expect(
        find.textContaining('manager.example.com ssh-ed25519'), findsOneWidget);
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('撤销'));
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('撤销主机信任'), findsOneWidget);
    await tester.tap(find.text('确认撤销'));
    await settleDatabaseWork();
    final revoked = await tester.runAsync(store.getAll);
    expect(revoked?.single.status.name, 'revoked');
    expect(tester.takeException(), isNull);
  });
}
