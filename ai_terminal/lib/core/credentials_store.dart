import 'dart:convert';
import 'dart:io' show Platform, Process;
import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart';
import 'package:flutter/foundation.dart' hide Key;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/daos.dart';

/// macOS Keychain 配置
const _macOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// 平台通道（用于获取 OS 级主密钥）
const _platform = MethodChannel('com.keiskei.aiterminal/security');

/// 凭据管理器
///
/// 优先使用 flutter_secure_storage（系统安全存储，如 macOS Keychain）。
/// 当系统安全存储不可用时（如未签名应用、Keychain 锁定等），
/// 降级到 SQLite + AES-256-CBC 加密存储（非明文）。
///
/// AES 主密钥通过 OS 原生 API 获取（不再硬编码在源码中）：
/// - macOS: Keychain 存储随机生成的 32 字节主密钥
/// - Windows: DPAPI (CryptProtectData) 保护主密钥，绑定用户账户
/// - Linux: /etc/machine-id 派生主密钥，绑定机器
class CredentialsStore {
  static late FlutterSecureStorage _storage;
  static bool _initialized = false;

  /// OS 级主密钥（通过 MethodChannel 从原生平台获取）
  static Key? _masterKey;
  static Encrypter? _encrypter;

  /// 旧版本硬编码密钥（仅用于解密旧格式数据，不再用于新加密）
  static final _legacyKey = Key.fromUtf8(
    'A1TerminalSecureKey2024XYZ!@#\$%^',
  );

  /// 生成密码学安全随机 IV（每次加密独立 IV，避免固定 IV 的频率分析风险）
  static IV _generateIv() {
    return IV.fromSecureRandom(16);
  }

  /// 初始化
  ///
  /// 完整初始化流程：加载主密钥 → 初始化 secure_storage
  /// 注意：此方法依赖 DbInit 已初始化（fallback 写入 SQLite 需要）
  /// 若只需主密钥（如 DbInit 加密 DB 需要），请调用 [loadMasterKey]
  static Future<void> init() async {
    if (_initialized) return;

    _storage = const FlutterSecureStorage(
      mOptions: _macOsOptions,
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    );

    // 从原生平台获取主密钥（若未提前加载）
    await loadMasterKey();

    _initialized = true;
    debugPrint('CredentialsStore: 初始化完成');
  }

  /// 仅加载 OS 主密钥（不依赖 DbInit，可在 DbInit.init() 之前调用）
  ///
  /// 用途：DbInit 需要 OS 主密钥作为 SQLCipher 密码，
  /// 但 CredentialsStore.init() 又依赖 DbInit，
  /// 形成循环依赖。此方法打破循环：
  /// 1. main.dart 先调用 loadMasterKey() 获取主密钥
  /// 2. 再调用 DbInit.init() 用主密钥打开加密 DB
  /// 3. 最后调用 CredentialsStore.init() 完成 fallback 路径就绪
  static Future<void> loadMasterKey() async {
    if (_masterKey != null) return; // 已加载

    // 策略 1（macOS 主路径）：通过 Dart Process.run 调用 ioreg 获取 IOPlatformUUID
    //
    // 为什么不用平台通道作为主路径？
    // 平台通道在 `open`（LaunchServices）启动时可能因 Flutter 引擎/窗口初始化
    // 时序问题而失败（返回 null），导致降级到 legacy key → 密钥在 IOPlatformUUID
    // 和 legacy 之间交替 → 每次启动都解不开上次的 DB → 归档 → 数据丢失。
    //
    // Dart Process.run 直接 fork/exec，不依赖 Flutter 引擎状态，启动方式无关
    // （`open` vs 终端 vs `flutter run` 均一致），彻底消除密钥交替问题。
    if (Platform.isMacOS) {
      final key = await _deriveKeyFromIOPlatformUUID();
      if (key != null) {
        _masterKey = key;
        _encrypter = Encrypter(AES(_masterKey!));
        debugPrint('CredentialsStore: 主密钥已从 IOPlatformUUID 派生 (Dart Process.run)');
        return;
      }
    }

    // 策略 2（备用）：平台通道（AppDelegate.swift 的 getMasterKey）
    try {
      final result = await _platform.invokeMethod<Uint8List>('getMasterKey');
      if (result != null && result.length == 32) {
        _masterKey = Key(result);
        _encrypter = Encrypter(AES(_masterKey!));
        debugPrint('CredentialsStore: 主密钥已从原生平台获取（备用路径）');
        return;
      }
    } catch (e) {
      debugPrint('CredentialsStore: 获取原生主密钥失败: $e');
    }

    // 策略 3（降级）：legacy key（仅在其他方式全部失败时使用）
    debugPrint('CredentialsStore: ⚠️ 降级使用旧版密钥（不推荐，可能导致数据不兼容）');
    _masterKey = _legacyKey;
    _encrypter = Encrypter(AES(_masterKey!));
  }

  /// 通过 ioreg 命令获取 IOPlatformUUID 并派生 SHA-256 主密钥
  ///
  /// IOPlatformUUID 是 macOS 系统安装时生成的硬件 UUID，重装系统才会变化，
  /// 不随应用签名/build/重签名变化，适合作为密钥派生源。
  static Future<Key?> _deriveKeyFromIOPlatformUUID() async {
    try {
      final result = await Process.run(
        '/usr/sbin/ioreg',
        ['-rd1', '-c', 'IOPlatformExpertDevice'],
      );
      if (result.exitCode != 0) {
        debugPrint('CredentialsStore: ioreg 退出码 ${result.exitCode}');
        return null;
      }
      final output = result.stdout as String;
      final match =
          RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(output);
      final uuid = match?.group(1);
      if (uuid == null || uuid.isEmpty) {
        debugPrint('CredentialsStore: ioreg 输出中未找到 IOPlatformUUID');
        return null;
      }
      final seed = 'com.keiskei.aiterminal.masterkey.v2:$uuid';
      final digest = crypto.sha256.convert(utf8.encode(seed));
      debugPrint(
          'CredentialsStore: IOPlatformUUID 获取成功 (prefix: ${uuid.substring(0, 8)})');
      return Key(Uint8List.fromList(digest.bytes));
    } catch (e) {
      debugPrint('CredentialsStore: ioreg 执行异常: $e');
      return null;
    }
  }

  /// 获取数据库加密密码（基于 OS 主密钥的 base64 编码）
  ///
  /// 用于 SQLite3MultipleCiphers 全库加密的 PRAGMA key
  /// 必须在 [loadMasterKey] 之后调用
  static String getDatabasePassword() {
    if (_masterKey == null) {
      // 极端情况：loadMasterKey 未调用，使用 legacy key
      return _legacyKey.base64;
    }
    return _masterKey!.base64;
  }

  /// 确保已初始化
  static Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await init();
    }
  }

  /// 加密（随机 IV，格式: ivBase64:cipherBase64）
  static String _encrypt(String plainText) {
    final iv = _generateIv();
    final encrypted = _encrypter!.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// 解密（兼容新格式 iv:cipher 和旧格式纯 cipher）
  /// 新数据用 OS 主密钥加密，旧数据用硬编码密钥加密
  static String? _decrypt(String cipherText) {
    try {
      if (cipherText.contains(':')) {
        // 新格式: ivBase64:cipherBase64（用当前主密钥解密）
        final parts = cipherText.split(':');
        if (parts.length == 2) {
          final iv = IV.fromBase64(parts[0]);
          return _encrypter!.decrypt64(parts[1], iv: iv);
        }
      }
      // 旧格式: 纯 cipherBase64（固定 IV，用旧版密钥解密）
      // 用旧版密钥创建临时解密器
      final legacyEncrypter = Encrypter(AES(_legacyKey));
      return legacyEncrypter.decrypt64(cipherText, iv: IV.fromUtf8('A1TerminalIV2024'));
    } catch (e) {
      // 尝试交叉解密：新格式用旧密钥
      try {
        if (cipherText.contains(':')) {
          final parts = cipherText.split(':');
          if (parts.length == 2) {
            final iv = IV.fromBase64(parts[0]);
            final legacyEncrypter = Encrypter(AES(_legacyKey));
            return legacyEncrypter.decrypt64(parts[1], iv: iv);
          }
        }
      } catch (_) {}
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

    // 2. 降级：AES 加密写入 SQLite
    try {
      final encrypted = _encrypt(value);
      await CredentialsFallbackDao.put(key, encrypted);
      debugPrint('✅ CredentialsStore: 保存到加密 SQLite 成功 hostId=$hostId type=$type');
      return true;
    } catch (e) {
      debugPrint('❌ CredentialsStore: 加密 SQLite 保存也失败: $e');
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
      debugPrint('⚠️ CredentialsStore: Keychain 读取失败，尝试加密 SQLite: $e');
    }

    // 2. 降级：从加密 SQLite 读取
    try {
      final encrypted = await CredentialsFallbackDao.get(key);
      if (encrypted != null) {
        final decrypted = _decrypt(encrypted);
        if (decrypted != null) {
          debugPrint('CredentialsStore: 从加密 SQLite 恢复凭据 hostId=$hostId type=$type');
          return decrypted;
        }
      }
    } catch (e) {
      debugPrint('CredentialsStore: 加密 SQLite 读取失败: $e');
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
      await CredentialsFallbackDao.delete(key);
    } catch (e) {
      debugPrint('CredentialsStore: 加密 SQLite 删除失败: $e');
    }
    debugPrint('CredentialsStore: 删除凭据 hostId=$hostId type=$type');
  }

  /// 删除主机所有凭据
  static Future<void> deleteAll(String hostId) async {
    await delete(hostId: hostId, type: 'password');
    await delete(hostId: hostId, type: 'privateKey');
    await delete(hostId: hostId, type: 'sudoPassword');
  }
}
