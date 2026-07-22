import Cocoa
import FlutterMacOS
import Security
import CryptoKit
import Darwin.sys.sysctl

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

  /// 获取应用主密钥（32 字节）
  ///
  /// 实现：从 macOS IOPlatformUUID 派生 SHA-256 密钥。
  ///
  /// 为什么不用 Keychain？
  /// 本项目使用 ad-hoc 签名 (`CODE_SIGN_IDENTITY = "-"`)，每次 `flutter build` 都会
  /// 重签名导致 cdhash 变化。Keychain 条目访问控制依赖 cdhash，变化后旧条目不可读
  /// (`errSecAuthFailed`)，且写入新条目后下次又因 cdhash 变化读不到，导致每次启动
  /// 都生成不同主密钥 → 加密 DB 解不开 → 数据丢失。
  ///
  /// 为什么用 IOPlatformUUID？
  /// - 绑定机器硬件，不依赖应用签名 → build/重签名/升级不影响
  /// - debug/release/profile 三种构建模式密钥一致 → 切换模式不丢数据
  /// - 比 Keychain 在 ad-hoc 场景下更可靠
  ///
  /// 安全性权衡：
  /// - 攻击者拿到 app bundle 无法解密（需先获取目标机器的 IOPlatformUUID）
  /// - 攻击者有目标机器的 root 权限才能获取 UUID（此时 Keychain 也防不住）
  /// - 重装系统会换 UUID，凭据需重新输入（与 Keychain ThisDeviceOnly 一致）
  private func getOrCreateMasterKey() -> FlutterStandardTypedData {
    let uuid = getIOPlatformUUID()
    let seed = "com.keiskei.aiterminal.masterkey.v2:\(uuid)".data(using: .utf8)!
    let digest = SHA256.hash(data: seed)
    NSLog("[Security] 主密钥已从 IOPlatformUUID 派生 (uuid prefix: \(String(uuid.prefix(8))))")
    return FlutterStandardTypedData(bytes: Data(digest))
  }

  /// 获取 IOPlatformUUID（硬件级 UUID，不随签名变化）
  ///
  /// 通过 `ioreg` 命令读取，对应 `IOPlatformExpertDevice` 的 `IOPlatformUUID` 属性。
  /// 这是 macOS 系统安装时生成的硬件 UUID，重装系统才会变化。
  /// 沙盒外可正常调用（本项目 app-sandbox = false）。
  private func getIOPlatformUUID() -> String {
    let task = Process()
    task.launchPath = "/usr/sbin/ioreg"
    task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
    let pipe = Pipe()
    task.standardOutput = pipe

    do {
      try task.run()
      task.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let output = String(data: data, encoding: .utf8) {
        // ioreg 输出形如:    "IOPlatformUUID" = "DEADBEFE-1234-5678-9ABC-DEF012345678"
        // 用正则提取等号右侧双引号内的 UUID
        let pattern = "\"IOPlatformUUID\"\\s*=\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           match.numberOfRanges >= 2,
           let uuidRange = Range(match.range(at: 1), in: output) {
          let uuid = String(output[uuidRange])
          NSLog("[Security] IOPlatformUUID 获取成功 (prefix: \(String(uuid.prefix(8))))")
          return uuid
        }
      }
    } catch {
      NSLog("[Security] ioreg 执行失败: \(error)")
    }

    // 极端 fallback：用 hw.uuid（通过 sysctl，作为 ioreg 失败的备份）
    var size = 0
    if sysctlbyname("kern.uuid", nil, &size, nil, 0) == 0, size > 0 {
      var buffer = [CChar](repeating: 0, count: size)
      if sysctlbyname("kern.uuid", &buffer, &size, nil, 0) == 0 {
        let uuid = String(cString: buffer)
        NSLog("[Security] ioreg 失败，sysctl kern.uuid 兜底成功 (prefix: \(String(uuid.prefix(8))))")
        return uuid
      }
    }

    // 终极 fallback：机器名 + 用户名（不稳定，仅防崩溃，不期望走到这）
    let fallback = "mac-fallback-\(Host.current().localizedName ?? "unknown")-\(NSUserName())"
    NSLog("[Security] ⚠️ IOPlatformUUID 所有途径失败，使用不稳定 fallback: \(fallback)")
    return fallback
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      registerSecurityChannel(flutterViewController)
    }
    super.applicationDidFinishLaunching(notification)
  }
}
