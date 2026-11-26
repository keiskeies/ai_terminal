import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database_key_manager.dart';

class DatabaseMigrationException implements Exception {
  const DatabaseMigrationException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'DatabaseMigrationException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

enum DatabaseMigrationPhase {
  backupVerified,
  copyToTemp,
  verifyTemp,
  createRollbackCopy,
  flushAndClose,
  atomicReplace,
  reopenAndSmokeTest,
  committed,
  failed,
}

extension on DatabaseMigrationPhase {
  String get wireName => switch (this) {
        DatabaseMigrationPhase.backupVerified => 'backup_verified',
        DatabaseMigrationPhase.copyToTemp => 'copy_to_temp',
        DatabaseMigrationPhase.verifyTemp => 'verify_temp',
        DatabaseMigrationPhase.createRollbackCopy => 'create_rollback_copy',
        DatabaseMigrationPhase.flushAndClose => 'flush_and_close',
        DatabaseMigrationPhase.atomicReplace => 'atomic_replace',
        DatabaseMigrationPhase.reopenAndSmokeTest => 'reopen_and_smoke_test',
        DatabaseMigrationPhase.committed => 'committed',
        DatabaseMigrationPhase.failed => 'failed',
      };
}

DatabaseMigrationPhase _phaseFromWire(String value) => switch (value) {
      'backup_verified' => DatabaseMigrationPhase.backupVerified,
      'copy_to_temp' => DatabaseMigrationPhase.copyToTemp,
      'verify_temp' => DatabaseMigrationPhase.verifyTemp,
      'create_rollback_copy' => DatabaseMigrationPhase.createRollbackCopy,
      'flush_and_close' => DatabaseMigrationPhase.flushAndClose,
      'atomic_replace' => DatabaseMigrationPhase.atomicReplace,
      'reopen_and_smoke_test' => DatabaseMigrationPhase.reopenAndSmokeTest,
      'committed' => DatabaseMigrationPhase.committed,
      'failed' => DatabaseMigrationPhase.failed,
      _ => DatabaseMigrationPhase.failed,
    };

class DatabaseMigrationState {
  DatabaseMigrationState({
    required this.id,
    required this.phase,
    required this.dbPath,
    required this.tempPath,
    required this.rollbackPath,
    required this.sourceBackupPath,
    required this.startedAt,
    required this.updatedAt,
    this.sourceVersion = 0,
    this.rowCounts = const {},
    this.error,
  });

  final String id;
  DatabaseMigrationPhase phase;
  final String dbPath;
  final String tempPath;
  final String rollbackPath;
  final String sourceBackupPath;
  final int startedAt;
  int updatedAt;
  int sourceVersion;
  Map<String, int> rowCounts;
  String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'phase': phase.wireName,
        'dbPath': dbPath,
        'tempPath': tempPath,
        'rollbackPath': rollbackPath,
        'sourceBackupPath': sourceBackupPath,
        'startedAt': startedAt,
        'updatedAt': updatedAt,
        'sourceVersion': sourceVersion,
        'rowCounts': rowCounts,
        'error': error,
      };

  factory DatabaseMigrationState.fromJson(Map<String, dynamic> json) {
    final rawCounts = json['rowCounts'];
    return DatabaseMigrationState(
      id: json['id'] as String,
      phase: _phaseFromWire(json['phase'] as String? ?? ''),
      dbPath: json['dbPath'] as String,
      tempPath: json['tempPath'] as String,
      rollbackPath: json['rollbackPath'] as String,
      sourceBackupPath: json['sourceBackupPath'] as String,
      startedAt: json['startedAt'] as int? ?? 0,
      updatedAt: json['updatedAt'] as int? ?? 0,
      sourceVersion: json['sourceVersion'] as int? ?? 0,
      rowCounts: rawCounts is Map
          ? rawCounts.map((k, v) => MapEntry(k.toString(), (v as num).toInt()))
          : const {},
      error: json['error'] as String?,
    );
  }
}

typedef MigrationEncryptedOpener = Future<Database> Function(
  String path,
  String password, {
  int? version,
  OnDatabaseCreateFn? onCreate,
  OnDatabaseVersionChangeFn? onUpgrade,
  bool readOnly,
  bool singleInstance,
});

typedef MigrationPlainOpener = Future<Database> Function(
  String path, {
  bool readOnly,
  bool singleInstance,
});

/// 移动端“明文 SQLite → SQLCipher”迁移。
///
/// 状态机与恢复策略见 docs/security-hardening-design.md 7.4 / 8.2。
/// 核心约束：
/// - 原库在 commit 前始终可恢复；
/// - 任何不确定状态都不新建空库；
/// - 回滚副本使用目标加密密钥，不产生长期明文 .bak。
class DatabaseMigrationService {
  DatabaseMigrationService({
    required this.keyManager,
    required this.openEncrypted,
    required this.openPlain,
    required this.schemaVersion,
    required this.onCreate,
    required this.onUpgrade,
  });

  final DatabaseKeyManager keyManager;
  final MigrationEncryptedOpener openEncrypted;
  final MigrationPlainOpener openPlain;
  final int schemaVersion;
  final OnDatabaseCreateFn onCreate;
  final OnDatabaseVersionChangeFn onUpgrade;

  static const String stateSuffix = '.migration_state.json';

  static String statePathFor(String dbPath) => '$dbPath$stateSuffix';

  Future<void> migratePlaintext(String dbPath, DatabaseKey key) async {
    final stateFile = File(statePathFor(dbPath));
    if (await stateFile.exists()) {
      throw DatabaseMigrationException(
        '已存在未完成的迁移状态，必须先恢复: ${stateFile.path}',
      );
    }
    if (!await File(dbPath).exists()) {
      throw DatabaseMigrationException('源数据库不存在: $dbPath');
    }

    final id = _randomId();
    final state = DatabaseMigrationState(
      id: id,
      phase: DatabaseMigrationPhase.backupVerified,
      dbPath: dbPath,
      tempPath: '$dbPath.migrating-$id.tmp',
      rollbackPath: '$dbPath.migrating-$id.rollback',
      sourceBackupPath: '$dbPath.migrating-$id.source',
      startedAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    Database? source;
    Database? temp;
    Database? rollback;
    try {
      await _deleteDbFiles(state.tempPath);
      await _deleteDbFiles(state.rollbackPath);
      await _deleteDbFiles(state.sourceBackupPath);

      source = await openPlain(dbPath, readOnly: false, singleInstance: false);
      await _checkpoint(source);
      await _assertIntegrity(source, '源库');
      final tables = await _userTables(source);
      final sourceColumns = <String, List<String>>{};
      final rowCounts = <String, int>{};
      for (final table in tables) {
        final name = table.name;
        sourceColumns[name] = await _columns(source, name);
        rowCounts[name] = await _count(source, name);
      }
      state.rowCounts = rowCounts;
      state.sourceVersion = await _userVersion(source);
      await _writeState(state);

      state.phase = DatabaseMigrationPhase.copyToTemp;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);

      temp = await openEncrypted(
        state.tempPath,
        key.secret,
        version: schemaVersion,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        readOnly: false,
        singleInstance: false,
      );
      await temp.transaction((txn) async {
        for (final table in tables) {
          final destColumns = await _columns(txn, table.name);
          if (destColumns.isEmpty) {
            if (table.sql != null) {
              await txn.execute(table.sql!);
            } else {
              throw DatabaseMigrationException(
                '源表 ${table.name} 在目标 schema 中不存在且没有建表语句',
              );
            }
          }
          final targetColumns =
              destColumns.isEmpty ? sourceColumns[table.name]! : destColumns;
          final common = sourceColumns[table.name]!
              .where(targetColumns.contains)
              .toList(growable: false);
          if (common.isEmpty) {
            throw DatabaseMigrationException(
              '源表 ${table.name} 与目标 schema 没有共同列，拒绝丢弃数据',
            );
          }
          await _copyRows(source!, txn, table.name, common);
        }
        final existingObjects = await _schemaObjectNames(txn);
        for (final object in await _schemaObjects(source!)) {
          if (existingObjects.contains(object.name)) continue;
          await txn.execute(object.sql);
        }
      });
      await _checkpoint(temp);
      await temp.close();
      temp = null;

      state.phase = DatabaseMigrationPhase.verifyTemp;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);

      temp = await openEncrypted(
        state.tempPath,
        key.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      await _assertIntegrity(temp, '临时加密库');
      final tempVersion = await _userVersion(temp);
      if (tempVersion != schemaVersion) {
        throw DatabaseMigrationException(
          '临时加密库 schema 版本异常: $tempVersion != $schemaVersion',
        );
      }
      for (final entry in rowCounts.entries) {
        if (!await _tableExists(temp, entry.key)) continue;
        final actual = await _count(temp, entry.key);
        if (actual != entry.value) {
          throw DatabaseMigrationException(
            '临时加密库行数不一致 ${entry.key}: ${entry.value} -> $actual',
          );
        }
      }
      await _checkpoint(temp);
      await temp.close();
      temp = null;
      await source.close();
      source = null;

      state.phase = DatabaseMigrationPhase.createRollbackCopy;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      await File(state.tempPath).copy(state.rollbackPath);
      rollback = await openEncrypted(
        state.rollbackPath,
        key.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      await _assertIntegrity(rollback, '加密回滚副本');
      for (final entry in rowCounts.entries) {
        if (!await _tableExists(rollback, entry.key)) continue;
        final actual = await _count(rollback, entry.key);
        if (actual != entry.value) {
          throw DatabaseMigrationException(
            '加密回滚副本行数不一致 ${entry.key}: ${entry.value} -> $actual',
          );
        }
      }
      await _checkpoint(rollback);
      await rollback.close();
      rollback = null;

      state.phase = DatabaseMigrationPhase.flushAndClose;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      await _deleteDbFiles(state.tempPath, keepMain: true);

      state.phase = DatabaseMigrationPhase.atomicReplace;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      await _atomicReplace(state);

      state.phase = DatabaseMigrationPhase.reopenAndSmokeTest;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      final smoke = await openEncrypted(
        dbPath,
        key.secret,
        version: null,
        readOnly: false,
        singleInstance: false,
      );
      try {
        await _assertIntegrity(smoke, '新加密库');
        for (final entry in rowCounts.entries) {
          if (!await _tableExists(smoke, entry.key)) continue;
          final actual = await _count(smoke, entry.key);
          if (actual != entry.value) {
            throw DatabaseMigrationException(
              '新加密库行数不一致 ${entry.key}: ${entry.value} -> $actual',
            );
          }
        }
        await smoke.execute('CREATE TEMP TABLE _aiterminal_smoke (v INTEGER)');
        await smoke.insert('_aiterminal_smoke', {'v': 1});
        final smokeRows = await smoke.query('_aiterminal_smoke');
        if (smokeRows.length != 1) {
          throw const DatabaseMigrationException('新加密库写入冒烟测试失败');
        }
      } finally {
        await smoke.close();
      }

      state.phase = DatabaseMigrationPhase.committed;
      state.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _writeState(state);
      await _cleanupCommitted(state);
      debugPrint('[DatabaseMigration] 明文→加密迁移完成 id=$id');
    } catch (e, st) {
      try {
        await source?.close();
      } catch (_) {}
      try {
        await temp?.close();
      } catch (_) {}
      try {
        await rollback?.close();
      } catch (_) {}
      try {
        await _handleFailure(state, e);
      } catch (rollbackError) {
        debugPrint('[DatabaseMigration] 失败回滚异常: $rollbackError');
      }
      debugPrint('[DatabaseMigration] 迁移失败 id=$id: $e\n$st');
      throw DatabaseMigrationException(
        '数据库加密迁移失败，原库已保留，状态文件: ${statePathFor(dbPath)}',
        cause: e,
      );
    }
  }

  /// 启动时先调用。存在状态文件时只允许恢复到安全点或确认已提交，
  /// 不允许删除当前库后继续“看起来是空的”初始化。
  Future<void> recoverIfNeeded(String dbPath) async {
    final stateFile = File(statePathFor(dbPath));
    if (!await stateFile.exists()) return;
    final DatabaseMigrationState state;
    try {
      final raw = jsonDecode(await stateFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('状态文件根节点不是对象');
      }
      state = DatabaseMigrationState.fromJson(raw);
    } catch (e) {
      throw DatabaseMigrationException(
        '迁移状态文件无法解析，拒绝自动新建数据库: ${stateFile.path}',
        cause: e,
      );
    }

    final dbExists = await File(dbPath).exists();
    final dbIsPlaintext = dbExists && await _isPlaintextSqlite(dbPath);

    if (state.phase == DatabaseMigrationPhase.committed) {
      final valid = await _encryptedDbHealthy(dbPath);
      if (valid) {
        await _cleanupCommitted(state);
        debugPrint('[DatabaseMigration] 已完成迁移的清理恢复完成');
        return;
      }
      await _restoreBestCopy(state, expectedEncrypted: true);
      await _deleteDbFiles(state.tempPath);
      await _deleteDbFiles(state.rollbackPath);
      await _cleanupStateOnly(state);
      return;
    }

    if (dbExists && dbIsPlaintext) {
      // 原库仍在，丢弃未提交的中间产物，随后重新迁移。
      var cleaned = true;
      cleaned = await _deleteDbFiles(state.tempPath) && cleaned;
      cleaned = await _deleteDbFiles(state.rollbackPath) && cleaned;
      cleaned = await _deleteDbFiles(state.sourceBackupPath) && cleaned;
      if (cleaned) {
        await _cleanupStateOnly(state);
      } else {
        debugPrint(
            '[DatabaseMigration] 中断现场清理失败，保留状态文件以便下次重试');
      }
      debugPrint('[DatabaseMigration] 检测到原明文库仍在，已清理中断迁移现场');
      return;
    }

    if (dbExists && await _encryptedDbHealthy(dbPath)) {
      // 替换已发生且新库验证通过；即使尚未写 committed 也可完成提交。
      await _cleanupCommitted(state);
      debugPrint('[DatabaseMigration] 中断迁移的新库验证通过，已完成提交清理');
      return;
    }

    // 当前库缺失或不可验证：只能用源备份/加密回滚副本恢复。
    await _restoreBestCopy(state, expectedEncrypted: false);
    await _deleteDbFiles(state.tempPath);
    await _deleteDbFiles(state.rollbackPath);
    await _cleanupStateOnly(state);
    debugPrint('[DatabaseMigration] 已从迁移副本恢复数据库');
  }

  Future<void> _restoreBestCopy(
    DatabaseMigrationState state, {
    required bool expectedEncrypted,
  }) async {
    final backup = File(state.sourceBackupPath);
    final rollback = File(state.rollbackPath);
    if (await backup.exists()) {
      await _deleteDbFiles(state.dbPath);
      await backup.rename(state.dbPath);
      await _restoreSidecars(state.sourceBackupPath, state.dbPath);
      return;
    }
    if (await rollback.exists()) {
      await _deleteDbFiles(state.dbPath);
      await rollback.copy(state.dbPath);
      await _deleteDbFiles(state.rollbackPath);
      return;
    }
    throw DatabaseMigrationException(
      expectedEncrypted
          ? '迁移已提交但新库不可用，且没有可恢复副本'
          : '迁移中断且没有可恢复的原库或回滚副本，拒绝新建空库',
    );
  }

  Future<void> _handleFailure(
    DatabaseMigrationState state,
    Object error,
  ) async {
    state.error = error.toString();
    if (state.phase == DatabaseMigrationPhase.committed) {
      return;
    }
    final backup = File(state.sourceBackupPath);
    if (await backup.exists()) {
      await _deleteDbFiles(state.dbPath);
      await backup.rename(state.dbPath);
      await _restoreSidecars(state.sourceBackupPath, state.dbPath);
    }
    state.phase = DatabaseMigrationPhase.failed;
    state.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _writeState(state);
  }

  Future<void> _cleanupCommitted(DatabaseMigrationState state) async {
    var cleaned = true;
    cleaned = await _deleteDbFiles(state.rollbackPath) && cleaned;
    cleaned = await _deleteDbFiles(state.tempPath) && cleaned;
    cleaned = await _deleteDbFiles(state.sourceBackupPath) && cleaned;
    if (!cleaned) {
      // 保留状态文件，下一次启动继续清理；明文源库不能因一次删除失败被静默留住。
      debugPrint('[DatabaseMigration] 中间产物清理失败，保留状态文件以便下次重试');
      return;
    }
    await _cleanupStateOnly(state);
  }

  Future<void> _cleanupStateOnly(DatabaseMigrationState state) async {
    final file = File(statePathFor(state.dbPath));
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[DatabaseMigration] 清理状态文件失败: $e');
    }
  }

  Future<void> _atomicReplace(DatabaseMigrationState state) async {
    final source = File(state.dbPath);
    final backup = File(state.sourceBackupPath);
    final temp = File(state.tempPath);
    if (!await temp.exists()) {
      throw const DatabaseMigrationException('临时加密库不存在，无法替换');
    }
    if (await backup.exists()) {
      await _deleteDbFiles(state.sourceBackupPath);
    }
    if (await source.exists()) {
      await source.rename(state.sourceBackupPath);
      await _moveSidecars(state.dbPath, state.sourceBackupPath);
    }
    try {
      await temp.rename(state.dbPath);
    } catch (e) {
      if (await backup.exists()) {
        await _deleteDbFiles(state.dbPath);
        await backup.rename(state.dbPath);
        await _restoreSidecars(state.sourceBackupPath, state.dbPath);
      }
      throw DatabaseMigrationException('原子替换失败，已尝试恢复原库', cause: e);
    }
  }

  Future<void> _writeState(DatabaseMigrationState state) async {
    final path = statePathFor(state.dbPath);
    final temp = File('$path.tmp');
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    try {
      // File.rename 在 Windows 上具备替换语义；不要先删目标，否则崩溃窗口内
      // 会丢失迁移状态并让下一次启动误判为“未开始迁移”。
      await temp.rename(path);
    } catch (e) {
      throw DatabaseMigrationException('写入迁移状态失败: $path', cause: e);
    }
  }

  Future<void> _copyRows(
    Database source,
    Transaction txn,
    String table,
    List<String> columns,
  ) async {
    const pageSize = 500;
    var offset = 0;
    while (true) {
      final rows = await source.query(table, limit: pageSize, offset: offset);
      if (rows.isEmpty) break;
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          table,
          {for (final column in columns) column: row[column]},
        );
      }
      await batch.commit(noResult: true);
      offset += rows.length;
      if (rows.length < pageSize) break;
    }
  }

  Future<List<_UserTable>> _userTables(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type='table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%'",
    );
    return rows
        .map((row) => _UserTable(
              row['name'] as String,
              row['sql'] as String?,
            ))
        .toList(growable: false);
  }

  Future<List<_SchemaObject>> _schemaObjects(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type IN ('index','trigger','view') "
      "AND sql IS NOT NULL",
    );
    return rows
        .map((row) =>
            _SchemaObject(row['name'] as String, row['sql'] as String))
        .toList(growable: false);
  }

  Future<Set<String>> _schemaObjectNames(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type IN ('index','trigger','view')",
    );
    return rows.map((row) => row['name'] as String).toSet();
  }

  Future<List<String>> _columns(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info("${_quote(table)}")');
    return rows.map((row) => row['name'] as String).toList(growable: false);
  }

  Future<bool> _tableExists(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  Future<int> _count(DatabaseExecutor db, String table) async {
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS c FROM "${_quote(table)}"');
    return (rows.first['c'] as num).toInt();
  }

  Future<int> _userVersion(DatabaseExecutor db) async {
    final rows = await db.rawQuery('PRAGMA user_version');
    return (rows.first.values.first as num).toInt();
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
      debugPrint('[DatabaseMigration] wal_checkpoint 失败: $e');
    }
  }

  Future<bool> _encryptedDbHealthy(String dbPath) async {
    final keys = await keyManager.candidates();
    for (final key in keys) {
      Database? db;
      try {
        db = await openEncrypted(
          dbPath,
          key.secret,
          version: null,
          readOnly: true,
          singleInstance: false,
        );
        await _assertIntegrity(db, '启动恢复检查');
        return true;
      } catch (_) {
        // 尝试下一个密钥槽
      } finally {
        try {
          await db?.close();
        } catch (_) {}
      }
    }
    return false;
  }

  Future<bool> _isPlaintextSqlite(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final header = await raf.read(16);
        if (header.length != 16) return false;
        const expected = 'SQLite format 3\u0000';
        return String.fromCharCodes(header) == expected;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _moveSidecars(String from, String to) async {
    for (final suffix in const ['-wal', '-shm']) {
      final file = File('$from$suffix');
      if (await file.exists()) {
        try {
          await file.rename('$to$suffix');
        } catch (e) {
          debugPrint('[DatabaseMigration] 移动 sidecar 失败 $suffix: $e');
        }
      }
    }
  }

  Future<void> _restoreSidecars(String from, String to) async {
    for (final suffix in const ['-wal', '-shm']) {
      final file = File('$from$suffix');
      if (await file.exists()) {
        try {
          await file.rename('$to$suffix');
        } catch (e) {
          debugPrint('[DatabaseMigration] 恢复 sidecar 失败 $suffix: $e');
        }
      }
    }
  }

  Future<bool> _deleteDbFiles(String path, {bool keepMain = false}) async {
    var ok = true;
    final suffixes =
        keepMain ? const ['-wal', '-shm', '-journal'] : const ['', '-wal', '-shm', '-journal'];
    for (final suffix in suffixes) {
      final file = File('$path$suffix');
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        ok = false;
        debugPrint('[DatabaseMigration] 删除文件失败 $path$suffix: $e');
      }
    }
    return ok;
  }

  String _quote(String identifier) => identifier.replaceAll('"', '""');

  String _randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}-'
        '${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

class _UserTable {
  const _UserTable(this.name, this.sql);

  final String name;
  final String? sql;
}

class _SchemaObject {
  const _SchemaObject(this.name, this.sql);

  final String name;
  final String sql;
}