import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_key_manager.dart';
import 'database_migration.dart';

enum DatabaseKeyRotationPhase {
  prepared,
  rollbackVerified,
  rekeyed,
  verified,
  committed,
  failed,
}

extension on DatabaseKeyRotationPhase {
  String get wireName => switch (this) {
        DatabaseKeyRotationPhase.prepared => 'prepared',
        DatabaseKeyRotationPhase.rollbackVerified => 'rollback_verified',
        DatabaseKeyRotationPhase.rekeyed => 'rekeyed',
        DatabaseKeyRotationPhase.verified => 'verified',
        DatabaseKeyRotationPhase.committed => 'committed',
        DatabaseKeyRotationPhase.failed => 'failed',
      };
}

DatabaseKeyRotationPhase _phaseFromWire(String value) => switch (value) {
      'prepared' => DatabaseKeyRotationPhase.prepared,
      'rollback_verified' => DatabaseKeyRotationPhase.rollbackVerified,
      'rekeyed' => DatabaseKeyRotationPhase.rekeyed,
      'verified' => DatabaseKeyRotationPhase.verified,
      'committed' => DatabaseKeyRotationPhase.committed,
      _ => DatabaseKeyRotationPhase.failed,
    };

class DatabaseKeyRotationState {
  DatabaseKeyRotationState({
    required this.id,
    required this.phase,
    required this.dbPath,
    required this.rollbackPath,
    required this.oldKeyId,
    required this.newKeyId,
    required this.startedAt,
    required this.updatedAt,
    this.error,
  });

  final String id;
  DatabaseKeyRotationPhase phase;
  final String dbPath;
  final String rollbackPath;
  final String oldKeyId;
  final String newKeyId;
  final int startedAt;
  int updatedAt;
  String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'phase': phase.wireName,
        'dbPath': dbPath,
        'rollbackPath': rollbackPath,
        'oldKeyId': oldKeyId,
        'newKeyId': newKeyId,
        'startedAt': startedAt,
        'updatedAt': updatedAt,
        'error': error,
      };

  factory DatabaseKeyRotationState.fromJson(Map<String, dynamic> json) =>
      DatabaseKeyRotationState(
        id: json['id'] as String,
        phase: _phaseFromWire(json['phase'] as String? ?? ''),
        dbPath: json['dbPath'] as String,
        rollbackPath: json['rollbackPath'] as String,
        oldKeyId: json['oldKeyId'] as String,
        newKeyId: json['newKeyId'] as String,
        startedAt: json['startedAt'] as int? ?? 0,
        updatedAt: json['updatedAt'] as int? ?? 0,
        error: json['error'] as String?,
      );
}

/// 数据库密钥轮换。
///
/// 调用前必须保证主库已关闭且没有进行中的 Agent 任务。轮换顺序：
/// pending 新密钥 -> 旧密钥加密回滚副本 -> PRAGMA rekey -> 新密钥验证
/// -> active 指针提升 -> 清理。任何阶段中断，启动恢复按 pending/active
/// 实际可打开关系判断，不盲目相信 active 指针。
class DatabaseKeyRotationService {
  DatabaseKeyRotationService({
    required this.keyManager,
    required this.openEncrypted,
  });

  final DatabaseKeyManager keyManager;
  final MigrationEncryptedOpener openEncrypted;

  static const String stateSuffix = '.key_rotation_state.json';

  static String statePathFor(String dbPath) => '$dbPath$stateSuffix';

  Future<DatabaseKey> rotate(String dbPath, DatabaseKey oldKey) async {
    final statePath = statePathFor(dbPath);
    if (await File(statePath).exists()) {
      throw DatabaseMigrationException(
        '存在未完成的密钥轮换状态，必须先恢复: $statePath',
      );
    }
    if (!await File(dbPath).exists()) {
      throw const DatabaseMigrationException('数据库不存在，无法轮换密钥');
    }

    final newKey = await keyManager.createPending();
    final id = _randomId();
    final state = DatabaseKeyRotationState(
      id: id,
      phase: DatabaseKeyRotationPhase.prepared,
      dbPath: dbPath,
      rollbackPath: '$dbPath.rotation-$id.rollback',
      oldKeyId: oldKey.id,
      newKeyId: newKey.id,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    Database? db;
    var rekeyAttempted = false;
    try {
      await _deleteDbFiles(state.rollbackPath);
      await _writeState(state);

      db = await openEncrypted(
        dbPath,
        oldKey.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      await _checkpoint(db);
      await _assertIntegrity(db, '轮换前数据库');
      final counts = await _rowCounts(db);
      await db.close();
      db = null;

      await File(dbPath).copy(state.rollbackPath);
      db = await openEncrypted(
        state.rollbackPath,
        oldKey.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      await _assertIntegrity(db, '密钥轮换回滚副本');
      await _assertCounts(db, counts, '密钥轮换回滚副本');
      await _checkpoint(db);
      await db.close();
      db = null;

      state.phase = DatabaseKeyRotationPhase.rollbackVerified;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);

      db = await openEncrypted(
        dbPath,
        oldKey.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      rekeyAttempted = true;
      try {
        await db.execute(
          "PRAGMA rekey = '${_escapeSqlString(newKey.secret)}';",
        );
      } catch (_) {
        // sqflite 异常文本会带上 SQL（含新密钥），这里必须丢弃原始异常，
        // 否则密钥会经启动失败页/日志泄露。
        throw const DatabaseMigrationException('PRAGMA rekey 执行失败');
      }
      await _checkpoint(db);
      await db.close();
      db = null;

      state.phase = DatabaseKeyRotationPhase.rekeyed;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);

      db = await openEncrypted(
        dbPath,
        newKey.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      await _assertIntegrity(db, '轮换后数据库');
      await _assertCounts(db, counts, '轮换后数据库');
      await db.execute('CREATE TEMP TABLE _aiterminal_rotate_smoke (v INTEGER)');
      await db.insert('_aiterminal_rotate_smoke', {'v': 1});
      final rows = await db.query('_aiterminal_rotate_smoke');
      if (rows.length != 1) {
        throw const DatabaseMigrationException('轮换后数据库写入冒烟测试失败');
      }
      await db.close();
      db = null;

      state.phase = DatabaseKeyRotationPhase.verified;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);

      await keyManager.promotePending();
      state.phase = DatabaseKeyRotationPhase.committed;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      if (await _deleteDbFiles(state.rollbackPath)) {
        await _deleteState(dbPath);
      } else {
        debugPrint('[DatabaseKeyRotation] 回滚副本清理失败，保留状态文件以便下次重试');
      }
      debugPrint(
        '[DatabaseKeyRotation] 密钥轮换完成 ${state.oldKeyId} -> ${state.newKeyId}');
      return newKey;
    } catch (e) {
      try {
        await db?.close();
      } catch (_) {}
      try {
        await _recoverAfterFailure(
          state,
          oldKey,
          newKey,
          rekeyAttempted: rekeyAttempted,
        );
      } catch (recoveryError) {
        debugPrint('[DatabaseKeyRotation] 失败恢复异常: $recoveryError');
      }
      throw DatabaseMigrationException(
        '数据库密钥轮换失败，状态文件: ${statePathFor(dbPath)}',
        cause: e,
      );
    }
  }

  /// 启动时必须在打开主库前调用。
  Future<void> recoverIfNeeded(String dbPath) async {
    final stateFile = File(statePathFor(dbPath));
    if (!await stateFile.exists()) return;
    final DatabaseKeyRotationState state;
    try {
      final raw = jsonDecode(await stateFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('状态文件根节点不是对象');
      }
      state = DatabaseKeyRotationState.fromJson(raw);
    } catch (e) {
      throw DatabaseMigrationException(
        '密钥轮换状态文件无法解析，拒绝自动新建数据库: ${stateFile.path}',
        cause: e,
      );
    }

    final dbExists = await File(dbPath).exists();
    if (!dbExists) {
      final cleaned =
          await _restoreRollback(state, verifyKey: await keyManager.readActive());
      await keyManager.discardPending();
      if (cleaned) {
        await _deleteState(dbPath);
      } else {
        debugPrint('[DatabaseKeyRotation] 恢复后回滚副本清理失败，保留状态文件');
      }
      return;
    }

    final pending = await keyManager.readPending();
    if (pending != null && await _healthy(dbPath, pending)) {
      await keyManager.promotePending();
      if (await _deleteDbFiles(state.rollbackPath)) {
        await _deleteState(dbPath);
      } else {
        debugPrint('[DatabaseKeyRotation] 回滚副本清理失败，保留状态文件');
      }
      debugPrint('[DatabaseKeyRotation] 中断轮换按 pending 密钥完成提交');
      return;
    }

    final active = await keyManager.readActive();
    if (active != null && await _healthy(dbPath, active)) {
      await keyManager.discardPending();
      if (await _deleteDbFiles(state.rollbackPath)) {
        await _deleteState(dbPath);
      } else {
        debugPrint('[DatabaseKeyRotation] 回滚副本清理失败，保留状态文件');
      }
      debugPrint('[DatabaseKeyRotation] 中断轮换按 active 密钥回退完成');
      return;
    }

    final cleaned = await _restoreRollback(state, verifyKey: active);
    await keyManager.discardPending();
    if (cleaned) {
      await _deleteState(dbPath);
    } else {
      debugPrint('[DatabaseKeyRotation] 恢复后回滚副本清理失败，保留状态文件');
    }
    debugPrint('[DatabaseKeyRotation] 已从轮换回滚副本恢复旧库');
  }

  Future<void> _recoverAfterFailure(
    DatabaseKeyRotationState state,
    DatabaseKey oldKey,
    DatabaseKey newKey, {
    required bool rekeyAttempted,
  }) async {
    state.error = 'rotation failed';
    if (await _healthy(state.dbPath, newKey)) {
      // rekey 已生效但 active 指针/状态提交未完成。保留 pending，由下次启动
      // 用新密钥打开并提升，不能在这里丢弃 pending。
      state.phase = DatabaseKeyRotationPhase.verified;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      return;
    }
    if (!rekeyAttempted && await _healthy(state.dbPath, oldKey)) {
      await keyManager.discardPending();
      await _deleteDbFiles(state.rollbackPath);
      state.phase = DatabaseKeyRotationPhase.failed;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      return;
    }
    await _restoreRollback(state, verifyKey: oldKey);
    await keyManager.discardPending();
    state.phase = DatabaseKeyRotationPhase.failed;
    state.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _writeState(state);
  }

  Future<bool> _restoreRollback(
    DatabaseKeyRotationState state, {
    DatabaseKey? verifyKey,
  }) async {
    final rollback = File(state.rollbackPath);
    if (!await rollback.exists()) {
      throw const DatabaseMigrationException(
        '密钥轮换失败且没有可用的回滚副本，拒绝新建空库',
      );
    }
    if (verifyKey != null && !await _healthy(state.rollbackPath, verifyKey)) {
      throw const DatabaseMigrationException(
        '密钥轮换回滚副本无法通过校验，拒绝覆盖当前数据库',
      );
    }
    await _deleteDbFiles(state.dbPath);
    await rollback.copy(state.dbPath);
    return _deleteDbFiles(state.rollbackPath);
  }

  Future<bool> _healthy(String path, DatabaseKey key) async {
    Database? db;
    try {
      db = await openEncrypted(
        path,
        key.secret,
        version: null,
        readOnly: true,
        singleInstance: false,
      );
      await _assertIntegrity(db, '密钥健康检查');
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  Future<Map<String, int>> _rowCounts(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );
    final counts = <String, int>{};
    for (final row in tables) {
      final name = row['name'] as String;
      final count = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM "${name.replaceAll('"', '""')}"',
      );
      counts[name] = (count.first['c'] as num).toInt();
    }
    return counts;
  }

  Future<void> _assertCounts(
    Database db,
    Map<String, int> expected,
    String label,
  ) async {
    final actual = await _rowCounts(db);
    for (final entry in expected.entries) {
      if (actual[entry.key] != entry.value) {
        throw DatabaseMigrationException(
          '$label 行数不一致 ${entry.key}: ${entry.value} -> ${actual[entry.key]}',
        );
      }
    }
  }

  Future<void> _assertIntegrity(DatabaseExecutor db, String label) async {
    final rows = await db.rawQuery('PRAGMA integrity_check');
    final ok = rows.length == 1 &&
        rows.first.values.first?.toString().toLowerCase() == 'ok';
    if (!ok) {
      throw DatabaseMigrationException('$label integrity_check 失败: $rows');
    }
  }

  Future<void> _checkpoint(Database db) async {
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (e) {
      debugPrint('[DatabaseKeyRotation] wal_checkpoint 失败: $e');
    }
  }

  Future<void> _writeState(DatabaseKeyRotationState state) async {
    final path = statePathFor(state.dbPath);
    final temp = File('$path.tmp');
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    try {
      await temp.rename(path);
    } catch (e) {
      throw DatabaseMigrationException('写入密钥轮换状态失败: $path', cause: e);
    }
  }

  Future<void> _deleteState(String dbPath) async {
    final file = File(statePathFor(dbPath));
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[DatabaseKeyRotation] 清理状态文件失败: $e');
    }
  }

  Future<bool> _deleteDbFiles(String path) async {
    var ok = true;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        ok = false;
        debugPrint('[DatabaseKeyRotation] 删除文件失败 $path$suffix: $e');
      }
    }
    return ok;
  }

  String _escapeSqlString(String value) => value.replaceAll("'", "''");

  String _randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}-'
        '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}