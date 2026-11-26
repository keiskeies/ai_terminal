import 'dart:convert';
import 'dart:io';

import 'package:ai_terminal/core/security/database_key_manager.dart';
import 'package:ai_terminal/core/security/database_key_rotation.dart';
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

DatabaseKey _key(int seed) => DatabaseKey(
      id: 'key-$seed',
      secret: base64Encode(List<int>.generate(32, (i) => (i + seed) & 0xff)),
    );

class _FakeKeyManager extends DatabaseKeyManager {
  _FakeKeyManager(this.active);

  DatabaseKey? active;
  DatabaseKey? pending;

  @override
  Future<DatabaseKey?> readActive() async => active;

  @override
  Future<DatabaseKey?> readPending() async => pending;

  @override
  Future<DatabaseKey> createPending() async {
    if (pending != null) {
      throw const DatabaseKeyUnavailableException('pending 已存在');
    }
    return pending = _key(200);
  }

  @override
  Future<void> promotePending() async {
    active = pending;
    pending = null;
  }

  @override
  Future<void> discardPending() async {
    pending = null;
  }

  @override
  Future<List<DatabaseKey>> candidates() async => [
        if (active != null) active!,
        if (pending != null) pending!,
      ];
}

Future<void> _seed(String path, DatabaseKey key) async {
  final db = await _openEncrypted(
    path,
    key.secret,
    version: 1,
    singleInstance: false,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
      );
    },
  );
  await db.insert('items', {'name': 'alpha'});
  await db.insert('items', {'name': 'beta'});
  await db.close();
}

Future<bool> _canRead(String path, DatabaseKey key) async {
  Database? db;
  try {
    db = await _openEncrypted(
      path,
      key.secret,
      version: null,
      readOnly: true,
      singleInstance: false,
    );
    await db.rawQuery('SELECT COUNT(*) FROM items');
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aiterminal_rotation_');
    dbPath = '${dir.path}/app_data.db';
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('轮换后仅新密钥可读，pending 提升为 active 并清理回滚副本', () async {
    final oldKey = _key(1);
    final manager = _FakeKeyManager(oldKey);
    await _seed(dbPath, oldKey);
    final service =
        DatabaseKeyRotationService(keyManager: manager, openEncrypted: _openEncrypted);

    final newKey = await service.rotate(dbPath, oldKey);

    expect(manager.active?.id, newKey.id);
    expect(manager.pending, isNull);
    expect(await _canRead(dbPath, newKey), isTrue);
    expect(await _canRead(dbPath, oldKey), isFalse);
    expect(await File(DatabaseKeyRotationService.statePathFor(dbPath)).exists(),
        isFalse);
    expect(
      dir
          .listSync()
          .map((entity) => entity.path)
          .where((path) => path.contains('.rotation-')),
      isEmpty,
    );
  });

  test('rekey 后 active 指针未提升时，启动恢复按 pending 密钥提交', () async {
    final oldKey = _key(1);
    final newKey = _key(2);
    final manager = _FakeKeyManager(oldKey)..pending = newKey;
    await _seed(dbPath, newKey);
    final state = DatabaseKeyRotationState(
      id: 'rot1',
      phase: DatabaseKeyRotationPhase.rekeyed,
      dbPath: dbPath,
      rollbackPath: '$dbPath.rotation-rot1.rollback',
      oldKeyId: oldKey.id,
      newKeyId: newKey.id,
      startedAt: 0,
      updatedAt: 0,
    );
    await File(state.rollbackPath).writeAsString('stale');
    await File(DatabaseKeyRotationService.statePathFor(dbPath))
        .writeAsString(jsonEncode(state.toJson()));

    final service =
        DatabaseKeyRotationService(keyManager: manager, openEncrypted: _openEncrypted);
    await service.recoverIfNeeded(dbPath);

    expect(manager.active?.id, newKey.id);
    expect(manager.pending, isNull);
    expect(await File(state.rollbackPath).exists(), isFalse);
    expect(await _canRead(dbPath, newKey), isTrue);
  });

  test('rekey 前失败时启动恢复保留 active 并丢弃 pending', () async {
    final oldKey = _key(1);
    final newKey = _key(2);
    final manager = _FakeKeyManager(oldKey)..pending = newKey;
    await _seed(dbPath, oldKey);
    final state = DatabaseKeyRotationState(
      id: 'rot2',
      phase: DatabaseKeyRotationPhase.prepared,
      dbPath: dbPath,
      rollbackPath: '$dbPath.rotation-rot2.rollback',
      oldKeyId: oldKey.id,
      newKeyId: newKey.id,
      startedAt: 0,
      updatedAt: 0,
    );
    await File(DatabaseKeyRotationService.statePathFor(dbPath))
        .writeAsString(jsonEncode(state.toJson()));

    final service =
        DatabaseKeyRotationService(keyManager: manager, openEncrypted: _openEncrypted);
    await service.recoverIfNeeded(dbPath);

    expect(manager.active?.id, oldKey.id);
    expect(manager.pending, isNull);
    expect(await _canRead(dbPath, oldKey), isTrue);
  });

  test('轮换中断且主库缺失时从回滚副本恢复旧库', () async {
    final oldKey = _key(1);
    final newKey = _key(2);
    final manager = _FakeKeyManager(oldKey)..pending = newKey;
    final state = DatabaseKeyRotationState(
      id: 'rot3',
      phase: DatabaseKeyRotationPhase.rollbackVerified,
      dbPath: dbPath,
      rollbackPath: '$dbPath.rotation-rot3.rollback',
      oldKeyId: oldKey.id,
      newKeyId: newKey.id,
      startedAt: 0,
      updatedAt: 0,
    );
    await _seed(state.rollbackPath, oldKey);
    await File(DatabaseKeyRotationService.statePathFor(dbPath))
        .writeAsString(jsonEncode(state.toJson()));

    final service =
        DatabaseKeyRotationService(keyManager: manager, openEncrypted: _openEncrypted);
    await service.recoverIfNeeded(dbPath);

    expect(manager.pending, isNull);
    expect(await File(state.rollbackPath).exists(), isFalse);
    expect(await _canRead(dbPath, oldKey), isTrue);
  });

  test('轮换状态损坏时拒绝继续', () async {
    final manager = _FakeKeyManager(_key(1));
    await File(DatabaseKeyRotationService.statePathFor(dbPath))
        .writeAsString('{broken');
    final service =
        DatabaseKeyRotationService(keyManager: manager, openEncrypted: _openEncrypted);

    await expectLater(
      service.recoverIfNeeded(dbPath),
      throwsA(isA<DatabaseMigrationException>()),
    );
  });
}