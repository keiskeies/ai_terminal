import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'hive_init.dart';

class AppLock {
  static final _localAuth = LocalAuthentication();

  /// 初始化应用锁
  static Future<bool> init() async {
    final enabled = HiveInit.settingsBox.get('appLockEnabled', defaultValue: false);
    if (!enabled) return true;

    // 如果启用了应用锁，验证身份
    return requireAuth();
  }

  /// 验证身份
  static Future<bool> requireAuth() async {
    try {
      final canAuth = await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();

      if (!canAuth) {
        // 设备不支持生物识别，允许访问
        return true;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: '验证身份以访问 AI Terminal',
        options: const AuthenticationOptions(
          biometricOnly: false,
        ),
      );

      return authenticated;
    } on PlatformException {
      return true; // 出错时允许访问
    }
  }

  /// 检查是否启用应用锁
  static Future<bool> isEnabled() async {
    return HiveInit.settingsBox.get('appLockEnabled', defaultValue: false);
  }

  /// 启用应用锁
  static Future<void> enable() async {
    await HiveInit.settingsBox.put('appLockEnabled', true);
  }

  /// 禁用应用锁
  static Future<void> disable() async {
    await HiveInit.settingsBox.put('appLockEnabled', false);
  }
}
