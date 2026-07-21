import Cocoa
import FlutterMacOS
import Security
import CryptoKit

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 注册 MethodChannel，提供 OS 级密钥管理
  private func registerSecurityChannel(_ registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: "SecurityPlugin")
    let channel = FlutterMethodChannel(
      name: "com.keiskei.aiterminal/security",
      binaryMessenger: registrar.messenger
    )

    channel.setMethodCallHandler { [weak self] (
      call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) in
      switch call.method {
      case "getMasterKey":
        result(self?.getOrCreateMasterKey())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 从 Keychain 读取或生成 32 字节随机主密钥
  /// 密钥存储在 Keychain 中，不在源码中，不随数据库文件泄露
  ///
  /// 重要：ad-hoc 签名 (`CODE_SIGN_IDENTITY = "-"`) 每次构建签名变化，
  /// 旧 Keychain 条目可能因签名不匹配无法读取（errSecAuthFailed）。
  /// 此时必须先删除旧条目再添加新条目，否则 SecItemAdd 会因 duplicate 静默失败，
  /// 导致每次启动生成不同主密钥 → 加密 DB 无法解密 → 启动黑屏。
  ///
  /// Debug 构建的特殊处理：
  /// 由于 debug 模式下 `flutter run` 每次都 ad-hoc 重签名，Keychain 条目每次都不可读，
  /// 会导致加密 DB 每次启动都被删除重建 → 用户数据每次 debug 启动都丢失。
  /// 因此 debug 构建改用**稳定派生密钥**（基于固定 seed 的 SHA-256），
  /// 不再走 Keychain。这样每次 debug 启动主密钥一致，加密 DB 能稳定打开。
  /// Release 构建仍走 Keychain 保持高安全性。
  private func getOrCreateMasterKey() -> FlutterStandardTypedData {
    #if DEBUG
    // Debug 构建：用稳定派生密钥（SHA-256 of 固定 seed），不依赖 Keychain
    // 注意：安全性较低（密钥可从二进制反编译得到），仅用于开发期 debug。
    // 严禁用于 release 构建。
    let stableSeed = "com.keiskei.aiterminal.debug.masterkey.v1".data(using: .utf8)!
    let digest = SHA256.hash(data: stableSeed)
    return FlutterStandardTypedData(bytes: Data(digest))
    #else
    // Release 构建：走 Keychain 原有逻辑
    let key = "com.keiskei.aiterminal.masterkey"

    // 1. 尝试从 Keychain 读取
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
    if readStatus == errSecSuccess,
       let data = item as? Data {
      return FlutterStandardTypedData(bytes: data)
    }

    // 2. 读取失败：删除可能存在的旧条目（签名变化导致不可访问的残留条目）
    //    忽略删除结果（条目可能本就不存在）
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    // 3. 生成新的 32 字节随机密钥
    var randomBytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, 32, &randomBytes)
    if status != errSecSuccess {
      // 极端情况：系统随机数生成失败，回退到 UUID 派生
      let uuid = UUID().uuidString
      let uuidBytes = Array(uuid.utf8)
      for i in 0..<32 {
        randomBytes[i] = uuidBytes[i % uuidBytes.count]
      }
    }
    let keyData = Data(randomBytes)

    // 4. 存入 Keychain（仅本设备、解锁后可用）
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecValueData as String: keyData,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus != errSecSuccess {
      // 添加仍失败时，至少返回密钥供本次运行使用（DB 会用此密钥加密）
      // 下次启动若仍读取失败，DbInit 会归档旧加密 DB 并新建空 DB（绝不再从 .bak 覆盖）
      NSLog("[Security] SecItemAdd failed: \(addStatus)")
    }

    return FlutterStandardTypedData(bytes: keyData)
    #endif
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      registerSecurityChannel(flutterViewController)
    }
    super.applicationDidFinishLaunching(notification)
  }
}
