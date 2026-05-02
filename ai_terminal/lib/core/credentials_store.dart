import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// macOS Keychain 配置
const _macOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);

/// 使用 flutter_secure_storage 的凭据管理器（跨平台安全存储）
class CredentialsStore {
  static Box<String>? _box;
  static late FlutterSecureStorage _storage;

  /// 初始化
  static Future<void> init() async {
    if (_box != null) return;
    _box = await Hive.openBox<String>('credentials');
    
    // 配置 secure storage
    _storage = const FlutterSecureStorage(
      mOptions: _macOsOptions,
    );
    
    debugPrint('CredentialsStore: 初始化完成');
  }

  /// 确保已初始化
  static Future<void> _ensureInitialized() async {
    if (_box == null || !_box!.isOpen) {
      await init();
    }
  }

  /// 保存凭据
  static Future<bool> save({
    required String hostId,
    required String type,
    required String value,
  }) async {
    await _ensureInitialized();
    
    try {
      final key = 'cred:$hostId:$type';
      
      debugPrint('CredentialsStore: 尝试保存 hostId=$hostId type=$type');
      
      // 保存到 flutter_secure_storage
      await _storage.write(key: key, value: value);
      
      // 同时保存到 Hive 作为备份
      await _box?.put(key, value);
      
      debugPrint('✅ CredentialsStore: 保存成功 hostId=$hostId type=$type');
      return true;
    } catch (e, stack) {
      debugPrint('❌ CredentialsStore.save 失败: $e');
      debugPrint('Stack: $stack');
      
      // 尝试只保存到 Hive（作为后备方案）
      try {
        final key = 'cred:$hostId:$type';
        await _box?.put(key, value);
        debugPrint('⚠️ 已保存到 Hive 作为后备: $key');
        return true;
      } catch (hiveError) {
        debugPrint('❌ Hive 保存也失败: $hiveError');
        return false;
      }
    }
  }

  /// 获取凭据（优先从 flutter_secure_storage 读取）
  static Future<String?> get({
    required String hostId,
    required String type,
  }) async {
    await _ensureInitialized();
    
    try {
      final key = 'cred:$hostId:$type';
      
      // 优先从 flutter_secure_storage 获取
      String? value = await _storage.read(key: key);
      
      // 如果没有，尝试从 Hive 获取
      if (value == null) {
        value = _box?.get(key);
        if (value != null) {
          debugPrint('CredentialsStore: 从 Hive 恢复凭据 hostId=$hostId type=$type');
        }
      }
      
      if (value == null) {
        debugPrint('⚠️ CredentialsStore: 未找到凭据 hostId=$hostId type=$type');
      }
      
      return value;
    } catch (e) {
      debugPrint('❌ CredentialsStore.get 失败: $e');
      return null;
    }
  }

  /// 删除凭据
  static Future<void> delete({
    required String hostId,
    required String type,
  }) async {
    await _ensureInitialized();
    
    try {
      final key = 'cred:$hostId:$type';
      await _storage.delete(key: key);
      await _box?.delete(key);
      debugPrint('CredentialsStore: 删除凭据 hostId=$hostId type=$type');
    } catch (e) {
      debugPrint('❌ CredentialsStore.delete 失败: $e');
    }
  }

  /// 删除主机所有凭据
  static Future<void> deleteAll(String hostId) async {
    await delete(hostId: hostId, type: 'password');
    await delete(hostId: hostId, type: 'privateKey');
  }
}
