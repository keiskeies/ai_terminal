import 'package:sqflite/sqflite.dart';

import '../db_init.dart';
import '../../models/ssh_host_key.dart';
import 'ssh_host_key_policy.dart';

const String sshHostKeysCreateSql = '''
  CREATE TABLE IF NOT EXISTS ssh_host_keys (
    route_key TEXT NOT NULL,
    alias TEXT NOT NULL,
    key_type TEXT NOT NULL,
    fingerprint_sha256 TEXT NOT NULL,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    status TEXT NOT NULL,
    source TEXT NOT NULL,
    confirmed_by TEXT NOT NULL,
    public_key_base64 TEXT,
    PRIMARY KEY (route_key, alias, key_type)
  )
''';

class SshHostKeyImportResult {
  const SshHostKeyImportResult({
    required this.added,
    required this.revoked,
    required this.skipped,
  });

  final int added;
  final int revoked;
  final int skipped;
}

class SshHostKeyStore {
  SshHostKeyStore({Database? databaseOverride})
      : _databaseOverride = databaseOverride;

  final Database? _databaseOverride;

  Database get _db => _databaseOverride ?? DbInit.db;

  Future<SshHostKey?> find({
    required String routeKey,
    required String alias,
    required String keyType,
  }) async {
    final rows = await _db.query(
      'ssh_host_keys',
      where: 'route_key = ? AND alias = ? AND key_type = ?',
      whereArgs: [routeKey, alias, keyType],
      limit: 1,
    );
    if (rows.isNotEmpty) return _fromRow(rows.first);
    final candidates = await _db.query(
      'ssh_host_keys',
      where: 'route_key = ? AND key_type = ?',
      whereArgs: [routeKey, keyType],
    );
    for (final row in candidates) {
      final storedAlias = row['alias']! as String;
      if (SshHostKeyPolicy.matchesAlias(storedAlias, alias)) {
        return _fromRow(row);
      }
    }
    return null;
  }

  Future<List<SshHostKey>> getAll() async {
    final rows =
        await _db.query('ssh_host_keys', orderBy: 'alias ASC, key_type ASC');
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<bool> trustFirstUse(SshHostKey key) async {
    final db = _databaseOverride ?? DbInit.db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'ssh_host_keys',
        where: 'route_key = ? AND key_type = ?',
        whereArgs: [key.routeKey, key.keyType],
      );
      for (final row in rows) {
        if (SshHostKeyPolicy.matchesAlias(row['alias']! as String, key.alias)) {
          return false;
        }
      }
      await txn.insert('ssh_host_keys', _toRow(key),
          conflictAlgorithm: ConflictAlgorithm.abort);
      return true;
    });
  }

  Future<bool> replaceTrusted({
    required String routeKey,
    required String alias,
    required String keyType,
    required String expectedFingerprint,
    required SshHostKey replacement,
  }) async {
    final db = _databaseOverride ?? DbInit.db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'ssh_host_keys',
        where: 'route_key = ? AND key_type = ?',
        whereArgs: [routeKey, keyType],
      );
      Map<String, Object?>? matched;
      for (final row in rows) {
        if (SshHostKeyPolicy.matchesAlias(row['alias']! as String, alias)) {
          matched = row;
          break;
        }
      }
      if (matched == null) return false;
      final current = _fromRow(matched);
      if (current.status != SshHostKeyStatus.trusted ||
          current.fingerprintSha256 != expectedFingerprint) {
        return false;
      }
      await txn.update(
        'ssh_host_keys',
        {
          ..._toRow(replacement),
        }..remove('first_seen_at'),
        where: 'route_key = ? AND alias = ? AND key_type = ?',
        whereArgs: [routeKey, current.alias, keyType],
      );
      return true;
    });
  }

  Future<bool> touch(SshHostKey key) async {
    final count = await _db.update(
      'ssh_host_keys',
      {'last_seen_at': DateTime.now().millisecondsSinceEpoch},
      where: 'route_key = ? AND alias = ? AND key_type = ? '
          'AND status = ? AND fingerprint_sha256 = ?',
      whereArgs: [
        key.routeKey,
        key.alias,
        key.keyType,
        SshHostKeyStatus.trusted.name,
        key.fingerprintSha256,
      ],
    );
    return count == 1;
  }

  Future<void> revoke(SshHostKey key) async {
    await _db.update(
      'ssh_host_keys',
      {
        'status': SshHostKeyStatus.revoked.name,
        'last_seen_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'route_key = ? AND alias = ? AND key_type = ?',
      whereArgs: [key.routeKey, key.alias, key.keyType],
    );
  }

  Future<SshHostKeyImportResult> importKeys(List<SshHostKey> keys) async {
    for (final key in keys) {
      SshHostKeyPolicy.validateKeyType(key.keyType);
      SshHostKeyPolicy.normalizeFingerprint(key.fingerprintSha256);
    }
    final db = _databaseOverride ?? DbInit.db;
    return db.transaction((txn) async {
      var added = 0;
      var revoked = 0;
      var skipped = 0;
      for (final key in keys) {
        final rows = await txn.query(
          'ssh_host_keys',
          where: 'route_key = ? AND key_type = ?',
          whereArgs: [key.routeKey, key.keyType],
        );
        Map<String, Object?>? matched;
        for (final row in rows) {
          if (SshHostKeyPolicy.matchesAlias(
              row['alias']! as String, key.alias)) {
            matched = row;
            break;
          }
        }
        if (matched == null) {
          await txn.insert('ssh_host_keys', _toRow(key),
              conflictAlgorithm: ConflictAlgorithm.abort);
          if (key.status == SshHostKeyStatus.revoked) {
            revoked++;
          } else {
            added++;
          }
          continue;
        }
        final current = _fromRow(matched);
        final canRevoke = key.status == SshHostKeyStatus.revoked &&
            current.status == SshHostKeyStatus.trusted &&
            current.fingerprintSha256 == key.fingerprintSha256;
        if (canRevoke) {
          await txn.update(
            'ssh_host_keys',
            {
              'status': SshHostKeyStatus.revoked.name,
              'last_seen_at': key.lastSeenAt.millisecondsSinceEpoch,
            },
            where: 'route_key = ? AND alias = ? AND key_type = ?',
            whereArgs: [key.routeKey, current.alias, key.keyType],
          );
          revoked++;
        } else {
          skipped++;
        }
      }
      return SshHostKeyImportResult(
          added: added, revoked: revoked, skipped: skipped);
    });
  }

  static Map<String, Object?> _toRow(SshHostKey key) => {
        'route_key': key.routeKey,
        'alias': key.alias,
        'key_type': key.keyType,
        'fingerprint_sha256': key.fingerprintSha256,
        'first_seen_at': key.firstSeenAt.millisecondsSinceEpoch,
        'last_seen_at': key.lastSeenAt.millisecondsSinceEpoch,
        'status': key.status.name,
        'source': key.source.name,
        'confirmed_by': key.confirmedBy,
        'public_key_base64': key.publicKeyBase64,
      };

  static SshHostKey _fromRow(Map<String, Object?> row) => SshHostKey(
        routeKey: row['route_key'] as String,
        alias: row['alias'] as String,
        keyType: row['key_type'] as String,
        fingerprintSha256: row['fingerprint_sha256'] as String,
        firstSeenAt:
            DateTime.fromMillisecondsSinceEpoch(row['first_seen_at'] as int),
        lastSeenAt:
            DateTime.fromMillisecondsSinceEpoch(row['last_seen_at'] as int),
        status: SshHostKeyStatus.values.firstWhere(
          (value) => value.name == row['status'],
          orElse: () => SshHostKeyStatus.revoked,
        ),
        source: SshHostKeySource.values.firstWhere(
          (value) => value.name == row['source'],
          orElse: () => SshHostKeySource.userConfirmed,
        ),
        confirmedBy: row['confirmed_by'] as String,
        publicKeyBase64: row['public_key_base64'] as String?,
      );
}
