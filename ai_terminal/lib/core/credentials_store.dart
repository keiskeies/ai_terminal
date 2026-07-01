import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' hide Key;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// macOS Keychain 配置
const _macOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// 凭据管理器
///
/// 优先使用 flutter_secure_storage（系统安全存储，如 macOS Keychain）。
/// 当系统安全存储不可用时（如未签名应用、Keychain 锁定等），
/// 降级到 Hive + AES-256-CBC 加密存储（非明文）。
///
/// 旧版本数据迁移：自动检测旧 Hive credentials box 中的明文数据，
/// 读取后加密保存并删除明文。
class CredentialsStore {
  static late FlutterSecureStorage _storage;
  static Box<String>? _fallbackBox;
  static bool _initialized = false;

  // AES 加密密钥（固定种子，用于 Hive 降级场景）
  // 注意：这不如系统 Keychain 安全，但远优于明文存储
  static final _encryptionKey = Key.fromUtf8(
    'A1TerminalSecureKey2024XYZ!@#\$%^',
  );
  static final _encrypter = Encrypter(AES(_encryptionKey));

  /// 生成密码学安全随机 IV（每次加密独立 IV，避免固定 IV 的频率分析风险）
  static IV _generateIv() {
    return IV.fromSecureRandom(16);
  }

  /// 初始化
  static Future<void> init() async {
    if (_initialized) return;

    _storage = const FlutterSecureStorage(
      mOptions: _macOsOptions,
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    );

    // 打开 Hive 降级 box（加密存储用）
    try {
      _fallbackBox = await Hive.openBox<String>('credentials_fallback');
    } catch (e) {
      debugPrint('CredentialsStore: 降级 box 打开失败: $e');
    }

    _initialized = true;
    debugPrint('CredentialsStore: 初始化完成');

    // 迁移旧数据
    await _migrateLegacyData();
  }

  /// 确保已初始化
  static Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await init();
    }
  }

  /// 迁移旧版本明文数据
  /// 旧版本将凭据明文存入 Hive 'credentials' box，此处读取并迁移到安全存储
  static Future<void> _migrateLegacyData() async {
    try {
      final legacyBox = await Hive.openBox<String>('credentials');
      if (legacyBox.isEmpty) {
        await legacyBox.close();
        return;
      }

      debugPrint('CredentialsStore: 检测到旧版明文数据，开始迁移...');
      var migrated = 0;
      for (final key in legacyBox.keys.toList()) {
        final value = legacyBox.get(key);
        if (value == null || value.isEmpty) continue;

        // 优先迁移到 secure_storage
        var saved = false;
        try {
          await _storage.write(key: key.toString(), value: value);
          saved = true;
        } catch (e) {
          debugPrint('CredentialsStore: 迁移到 secure_storage 失败 ($key): $e');
        }

        // secure_storage 失败时迁移到加密 Hive
        if (!saved) {
          try {
            final encrypted = _encrypt(value);
            await _fallbackBox?.put(key, encrypted);
            saved = true;
          } catch (e) {
            debugPrint('CredentialsStore: 迁移到加密 Hive 失败 ($key): $e');
          }
        }

        if (saved) {
          await legacyBox.delete(key);
          migrated++;
        }
      }

      if (migrated > 0) {
        debugPrint('CredentialsStore: 迁移完成，共 $migrated 条凭据');
      }
      await legacyBox.close();
    } catch (e) {
      debugPrint('CredentialsStore: 旧数据迁移跳过: $e');
    }
  }

  /// 加密（随机 IV，格式: ivBase64:cipherBase64）
  static String _encrypt(String plainText) {
    final iv = _generateIv();
    final encrypted = _encrypter.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// 解密（兼容新格式 iv:cipher 和旧格式纯 cipher）
  static String? _decrypt(String cipherText) {
    try {
      if (cipherText.contains(':')) {
        final parts = cipherText.split(':');
        if (parts.length == 2) {
          final iv = IV.fromBase64(parts[0]);
          return _encrypter.decrypt64(parts[1], iv: iv);
        }
      }
      // 旧格式: 纯 cipherBase64（固定 IV，向后兼容）
      return _encrypter.decrypt64(cipherText, iv: IV.fromUtf8('A1TerminalIV2024'));
    } catch (e) {
      debugPrint('CredentialsStore: 解密失败: $e');
      return null;
    }
  }

  /// 保存凭据
  /// 成功返回 true，失败返回 false
  static Future<bool> save({
    required String hostId,
    required String type,
    required String value,
  }) async {
    await _ensureInitialized();

    final key = 'cred:$hostId:$type';
    debugPrint('CredentialsStore: 尝试保存 hostId=$hostId type=$type');

    // 1. 尝试 secure_storage
    try {
      await _storage.write(key: key, value: value);
      debugPrint('✅ CredentialsStore: 保存到 Keychain 成功 hostId=$hostId type=$type');
      return true;
    } catch (e, stack) {
      debugPrint('⚠️ CredentialsStore: Keychain 写入失败，降级到加密存储: $e');
      debugPrint('Stack: $stack');
    }

    // 2. 降级：AES 加密写入 Hive
    try {
      final encrypted = _encrypt(value);
      await _fallbackBox?.put(key, encrypted);
      debugPrint('✅ CredentialsStore: 保存到加密 Hive 成功 hostId=$hostId type=$type');
      return true;
    } catch (e) {
      debugPrint('❌ CredentialsStore: 加密 Hive 保存也失败: $e');
      return false;
    }
  }

  /// 获取凭据
  static Future<String?> get({
    required String hostId,
    required String type,
  }) async {
    await _ensureInitialized();

    final key = 'cred:$hostId:$type';

    // 1. 优先从 secure_storage 读取
    try {
      final value = await _storage.read(key: key);
      if (value != null) {
        return value;
      }
    } catch (e) {
      debugPrint('⚠️ CredentialsStore: Keychain 读取失败，尝试加密 Hive: $e');
    }

    // 2. 降级：从加密 Hive 读取
    try {
      final encrypted = _fallbackBox?.get(key);
      if (encrypted != null) {
        final decrypted = _decrypt(encrypted);
        if (decrypted != null) {
          debugPrint('CredentialsStore: 从加密 Hive 恢复凭据 hostId=$hostId type=$type');
          return decrypted;
        }
      }
    } catch (e) {
      debugPrint('CredentialsStore: 加密 Hive 读取失败: $e');
    }

    debugPrint('⚠️ CredentialsStore: 未找到凭据 hostId=$hostId type=$type');
    return null;
  }

  /// 删除凭据
  static Future<void> delete({
    required String hostId,
    required String type,
  }) async {
    await _ensureInitialized();

    final key = 'cred:$hostId:$type';
    try {
      await _storage.delete(key: key);
    } catch (e) {
      debugPrint('CredentialsStore: Keychain 删除失败: $e');
    }
    try {
      await _fallbackBox?.delete(key);
    } catch (e) {
      debugPrint('CredentialsStore: 加密 Hive 删除失败: $e');
    }
    debugPrint('CredentialsStore: 删除凭据 hostId=$hostId type=$type');
  }

  /// 删除主机所有凭据
  static Future<void> deleteAll(String hostId) async {
    await delete(hostId: hostId, type: 'password');
    await delete(hostId: hostId, type: 'privateKey');
  }
}
