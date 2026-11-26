import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 数据库密钥不可用（密钥被删除、Keystore 失效、Keychain 不可访问等）。
///
/// 调用方必须 fail closed：不得生成新密钥覆盖现有库，也不得新建空库。
class DatabaseKeyUnavailableException implements Exception {
  const DatabaseKeyUnavailableException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'DatabaseKeyUnavailableException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

class DatabaseKey {
  const DatabaseKey({required this.id, required this.secret});

  /// 非秘密的密钥标识，仅用于审计和轮换状态。
  final String id;

  /// base64(32 字节随机密钥)，只交给 SQLCipher，不写日志、不进数据库。
  final String secret;

  Uint8List get bytes => base64Decode(secret);

  @override
  bool operator ==(Object other) => other is DatabaseKey && other.secret == secret;

  @override
  int get hashCode => secret.hashCode;
}

enum DatabaseKeySlot { active, pending }

/// 移动端数据库密钥管理。
///
/// - Android: 原生 Keystore 中不可导出的 AES-256-GCM 包装密钥加密 32 字节
///   数据库密钥，仅返回解包后的密钥；包装密钥本身不作为 SQLCipher 口令。
/// - iOS: 32 字节随机密钥写入 Keychain（first_unlock_this_device），
///   随系统备份迁移到新设备时不可用，表现为密钥缺失并 fail closed。
/// - 桌面端不使用本类，继续沿用 CredentialsStore 的机器绑定主密钥。
class DatabaseKeyManager {
  DatabaseKeyManager({
    MethodChannel? channel,
    FlutterSecureStorage? storage,
  })  : _channel = channel ??
            const MethodChannel('com.keiskei.aiterminal/security'),
        _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  static final DatabaseKeyManager instance = DatabaseKeyManager();

  static const _activeIdKey = 'aiterminal.db_key.active.id';
  static const _activeSecretKey = 'aiterminal.db_key.active.secret';
  static const _pendingIdKey = 'aiterminal.db_key.pending.id';
  static const _pendingSecretKey = 'aiterminal.db_key.pending.secret';

  final MethodChannel _channel;
  final FlutterSecureStorage _storage;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  Future<DatabaseKey?> readActive() => _read(DatabaseKeySlot.active);

  Future<DatabaseKey?> readPending() => _read(DatabaseKeySlot.pending);

  /// 已有库但没有密钥时必须调用此方法并 let 异常上抛，禁止创建新密钥。
  Future<DatabaseKey> requireActive() async {
    final active = await readActive();
    if (active != null) return active;
    final pending = await readPending();
    if (pending != null) return pending;
    throw const DatabaseKeyUnavailableException(
      '数据库密钥缺失：设备安全存储中没有可用的 active/pending 密钥',
    );
  }

  /// 首次创建数据库或迁移明文库时生成 active 密钥。
  Future<DatabaseKey> getOrCreateActive() async {
    final existing = await readActive();
    if (existing != null) return existing;
    return _create(DatabaseKeySlot.active);
  }

  /// 轮换第 1 步：写入 pending 槽，失败时原库与原 active 密钥保持不变。
  Future<DatabaseKey> createPending() => _create(DatabaseKeySlot.pending);

  Future<void> promotePending() async {
    _ensureMobile();
    if (Platform.isAndroid) {
      await _invoke('promotePendingDatabaseKey');
      return;
    }
    final pending = await readPending();
    if (pending == null) {
      throw const DatabaseKeyUnavailableException('pending 密钥不存在，无法提升');
    }
    await _writeSecure(DatabaseKeySlot.active, pending);
    await _deleteSecure(DatabaseKeySlot.pending);
  }

  Future<void> discardPending() async {
    _ensureMobile();
    if (Platform.isAndroid) {
      await _invoke('discardPendingDatabaseKey');
      return;
    }
    await _deleteSecure(DatabaseKeySlot.pending);
  }

  /// 启动恢复时按 active → pending 尝试；不含任何硬编码/旧版固定密钥。
  Future<List<DatabaseKey>> candidates() async {
    final keys = <DatabaseKey>[];
    final active = await readActive();
    if (active != null) keys.add(active);
    final pending = await readPending();
    if (pending != null && !keys.contains(pending)) keys.add(pending);
    return keys;
  }

  Future<DatabaseKey?> _read(DatabaseKeySlot slot) async {
    _ensureMobile();
    if (Platform.isAndroid) {
      final result = await _invoke('readDatabaseKey', {'slot': slot.name});
      if (result == null) return null;
      return _fromMap(result, slot);
    }
    final id = await _storage.read(key: _slotIdKey(slot));
    final secret = await _storage.read(key: _slotSecretKey(slot));
    if (id == null && secret == null) return null;
    if (id == null || secret == null) {
      throw DatabaseKeyUnavailableException(
        '${slot.name} 密钥元数据不完整（id/secret 缺失）',
      );
    }
    return _validate(DatabaseKey(id: id, secret: secret), slot);
  }

  Future<DatabaseKey> _create(DatabaseKeySlot slot) async {
    _ensureMobile();
    if (Platform.isAndroid) {
      final result =
          await _invoke('createDatabaseKey', {'slot': slot.name});
      return _fromMap(result, slot);
    }
    final key = _generateKey();
    await _writeSecure(slot, key);
    return key;
  }

  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<dynamic>(method, args);
    } on PlatformException catch (e) {
      throw DatabaseKeyUnavailableException(
        'Android Keystore 操作失败: ${e.code}',
        cause: e.message,
      );
    } on MissingPluginException catch (e) {
      throw DatabaseKeyUnavailableException(
        'Android 安全存储通道不可用',
        cause: e,
      );
    }
  }

  DatabaseKey _fromMap(dynamic value, DatabaseKeySlot slot) {
    if (value is! Map) {
      throw const DatabaseKeyUnavailableException('平台返回的密钥格式无效');
    }
    final id = value['id'];
    final secret = value['secret'];
    if (id is! String || secret is! String) {
      throw const DatabaseKeyUnavailableException('平台返回的密钥字段缺失');
    }
    return _validate(DatabaseKey(id: id, secret: secret), slot);
  }

  DatabaseKey _validate(DatabaseKey key, DatabaseKeySlot slot) {
    if (key.id.isEmpty) {
      throw DatabaseKeyUnavailableException('${slot.name} 密钥 id 为空');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(key.secret);
    } on FormatException catch (e) {
      throw DatabaseKeyUnavailableException(
        '${slot.name} 密钥编码损坏，拒绝使用',
        cause: e,
      );
    }
    if (bytes.length != 32) {
      throw DatabaseKeyUnavailableException(
        '${slot.name} 密钥长度异常: ${bytes.length} 字节',
      );
    }
    return key;
  }

  DatabaseKey _generateKey() {
    final random = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    final idBytes = Uint8List(8);
    for (var i = 0; i < idBytes.length; i++) {
      idBytes[i] = random.nextInt(256);
    }
    final id = idBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return DatabaseKey(id: id, secret: base64Encode(bytes));
  }

  Future<void> _writeSecure(DatabaseKeySlot slot, DatabaseKey key) async {
    await _storage.write(key: _slotSecretKey(slot), value: key.secret);
    await _storage.write(key: _slotIdKey(slot), value: key.id);
  }

  Future<void> _deleteSecure(DatabaseKeySlot slot) async {
    await _storage.delete(key: _slotSecretKey(slot));
    await _storage.delete(key: _slotIdKey(slot));
  }

  String _slotIdKey(DatabaseKeySlot slot) =>
      slot == DatabaseKeySlot.active ? _activeIdKey : _pendingIdKey;

  String _slotSecretKey(DatabaseKeySlot slot) =>
      slot == DatabaseKeySlot.active ? _activeSecretKey : _pendingSecretKey;

  void _ensureMobile() {
    if (!isMobile) {
      throw const DatabaseKeyUnavailableException(
        'DatabaseKeyManager 仅用于 Android/iOS',
      );
    }
  }
}