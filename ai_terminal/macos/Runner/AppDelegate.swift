import Cocoa
import FlutterMacOS
import Security

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
  private func getOrCreateMasterKey() -> FlutterStandardTypedData {
    let key = "com.keiskei.aiterminal.masterkey"

    // 1. 尝试从 Keychain 读取
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
       let data = item as? Data {
      return FlutterStandardTypedData(bytes: data)
    }

    // 2. 生成新的 32 字节随机密钥
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

    // 3. 存入 Keychain（仅本设备、解锁后可用）
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: key,
      kSecValueData as String: keyData,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemAdd(addQuery as CFDictionary, nil)

    return FlutterStandardTypedData(bytes: keyData)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      registerSecurityChannel(flutterViewController)
    }
    super.applicationDidFinishLaunching(notification)
  }
}
