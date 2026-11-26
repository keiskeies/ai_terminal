import 'dart:convert';
import 'dart:io';

import 'package:ai_terminal/core/security/database_key_manager.dart';
import 'package:ai_terminal/core/security/database_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openEncrypted(
  String path,
  String password, {
  int? version,
  OnDatabaseCreateFn? onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
  bool readOnly = false,
  bool singleInstance = true,
}) {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      readOnly: readOnly,
      singleInstance: singleInstance,
      onConfigure: (db) async {
        await db.execute("PRAGMA key = '${password.replaceAll("'", "''")}';");
      },
    ),
  );
}

Future<Database> _openPlain(
  String path, {
  bool readOnly = false,
  bool singleInstance = true,
}) {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      readOnly: readOnly,
      singleInstance: singleInstance,
    ),
  );
}

Future<void> _createSchema(Database db, int version) async {
  await db.execute(
    'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
  );
  await db.execute('CREATE INDEX idx_items_name ON items(name)');
  await db.execute(
    'CREATE TABLE migration_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
}

Future<bool> _isPlaintext(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  final raf = await file.open();
  try {
    final header = await raf.read(16);
    return String.fromCharCodes(header) == 'SQLite format 3\u0000';
  } finally {
    await raf.close();
  }
}

Future<void> _writeState(
  String dbPath,
  DatabaseMigrationState state,
) async {
  await File(DatabaseMigrationService.statePathFor(dbPath))
      .writeAsString(jsonEncode(state.toJson()), flush: true);
}

DatabaseMigrationState _state(
  String dbPath,
  String id, {
  DatabaseMigrationPhase phase = DatabaseMigrationPhase.atomicReplace,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return DatabaseMigrationState(
    id: id,
    phase: phase,
    dbPath: dbPath,
    tempPath: '$dbPath.migrating-$id.tmp',
    rollbackPath: '$dbPath.migrating-$id.rollback',
    sourceBackupPath: '$dbPath.migrating-$id.source',
    startedAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late String dbPath;
  late DatabaseKey key;
  late DatabaseMigrationService service;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aiterminal_migration_');
    dbPath = '${dir.path}/app_data.db';
    key = DatabaseKey(
      id: 'test-key',
      secret: base64Encode(List<int>.generate(32, (i) => i)),
    );
    service = DatabaseMigrationService(
      keyManager: DatabaseKeyManager(),
      openEncrypted: _openEncrypted,
      openPlain: _openPlain,
      schemaVersion: 1,
      onCreate: _createSchema,
      onUpgrade: (db, oldVersion, newVersion) async {},
    );
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('明文库成功迁移到加密库并清理副本', () async {
    final source = await _openPlain(
      dbPath,
      singleInstance: false,
    ).then((db) async {
      await _createSchema(db, 1);
      await db.insert('items', {'name': 'web-1'});
      await db.insert('items', {'name': 'web-2'});
      return db;
    });
    await source.close();
    expect(await _isPlaintext(dbPath), isTrue);

    await service.migratePlaintext(dbPath, key);

    expect(await _isPlaintext(dbPath), isFalse);
    final plain = await _openPlain(dbPath, singleInstance: false);
    try {
      await expectLater(
        plain.rawQuery('SELECT count(*) FROM sqlite_master'),
        throwsA(isA<DatabaseException>()),
      );
    } finally {
      await plain.close();
    }
    final db = await _openEncrypted(
      dbPath,
      key.secret,
      singleInstance: false,
    );
    try {
      final rows = await db.query('items', orderBy: 'id');
      expect(rows.map((row) => row['name']), ['web-1', 'web-2']);
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      expect(integrity.first.values.first, 'ok');
    } finally {
      await db.close();
    }

    final leftovers = dir
        .listSync()
        .map((entity) => entity.path)
        .where((path) => path.contains('.migrating-') ||
            path.endsWith(DatabaseMigrationService.stateSuffix))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('迁移复制失败时原明文库保持可读，不创建空库', () async {
    final source = await _openPlain(dbPath, singleInstance: false);
    await source.execute('CREATE TABLE strict_items (id INTEGER PRIMARY KEY)');
    await source.insert('strict_items', {'id': 1});
    await source.close();

    final failing = DatabaseMigrationService(
      keyManager: DatabaseKeyManager(),
      openEncrypted: _openEncrypted,
      openPlain: _openPlain,
      schemaVersion: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE strict_items ('
          'id INTEGER PRIMARY KEY, required_value TEXT NOT NULL)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {},
    );

    await expectLater(
      failing.migratePlaintext(dbPath, key),
      throwsA(isA<DatabaseMigrationException>()),
    );
    expect(await _isPlaintext(dbPath), isTrue);
    final plain = await _openPlain(dbPath, singleInstance: false);
    try {
      final rows = await plain.query('strict_items');
      expect(rows, hasLength(1));
    } finally {
      await plain.close();
    }
  });

  test('中断迁移发现原明文库仍在时清理中间产物并保留原库', () async {
    final source = await _openPlain(dbPath, singleInstance: false);
    await _createSchema(source, 1);
    await source.insert('items', {'name': 'keep-me'});
    await source.close();

    final state = _state(dbPath, 'interrupted', phase: DatabaseMigrationPhase.copyToTemp);
    for (final path in [state.tempPath, state.rollbackPath, state.sourceBackupPath]) {
      await File(path).writeAsString('stale');
    }
    await _writeState(dbPath, state);

    await service.recoverIfNeeded(dbPath);

    expect(await _isPlaintext(dbPath), isTrue);
    expect(await File(state.tempPath).exists(), isFalse);
    expect(await File(state.rollbackPath).exists(), isFalse);
    expect(await File(state.sourceBackupPath).exists(), isFalse);
    expect(
      await File(DatabaseMigrationService.statePathFor(dbPath)).exists(),
      isFalse,
    );
    final plain = await _openPlain(dbPath, singleInstance: false);
    try {
      final rows = await plain.query('items');
      expect(rows.single['name'], 'keep-me');
    } finally {
      await plain.close();
    }
  });

  test('替换后原库缺失时从源备份恢复，不新建空库', () async {
    final source = await _openPlain(dbPath, singleInstance: false);
    await _createSchema(source, 1);
    await source.insert('items', {'name': 'restore-me'});
    await source.close();

    final state = _state(dbPath, 'missing-db');
    await File(dbPath).rename(state.sourceBackupPath);
    await _writeState(dbPath, state);

    await service.recoverIfNeeded(dbPath);

    expect(await _isPlaintext(dbPath), isTrue);
    expect(await File(state.sourceBackupPath).exists(), isFalse);
    expect(
      await File(DatabaseMigrationService.statePathFor(dbPath)).exists(),
      isFalse,
    );
    final plain = await _openPlain(dbPath, singleInstance: false);
    try {
      expect((await plain.query('items')).single['name'], 'restore-me');
    } finally {
      await plain.close();
    }
  });

  test('没有源库和回滚副本时恢复失败且不会创建空库', () async {
    final state = _state(dbPath, 'no-copy');
    await _writeState(dbPath, state);

    await expectLater(
      service.recoverIfNeeded(dbPath),
      throwsA(isA<DatabaseMigrationException>()),
    );
    expect(await File(dbPath).exists(), isFalse);
  });

  test('状态文件损坏时拒绝继续并保留数据库', () async {
    final source = await _openPlain(dbPath, singleInstance: false);
    await _createSchema(source, 1);
    await source.close();
    final statePath = DatabaseMigrationService.statePathFor(dbPath);
    await File(statePath).writeAsString('{not-json');

    await expectLater(
      service.recoverIfNeeded(dbPath),
      throwsA(isA<DatabaseMigrationException>()),
    );
    expect(await _isPlaintext(dbPath), isTrue);
    expect(await File(statePath).exists(), isTrue);
  });
}