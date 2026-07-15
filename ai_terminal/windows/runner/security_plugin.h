#ifndef SECURITY_PLUGIN_H_
#define SECURITY_PLUGIN_H_

#include <flutter/flutter_plugin.h>

// Windows DPAPI 安全插件
// 使用 CryptProtectData 保护主密钥，绑定当前用户账户
class SecurityPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  SecurityPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~SecurityPlugin();

 private:
  flutter::PluginRegistrarWindows* registrar_;

  // MethodChannel 回调
  void HandleMethodCall(
      const flutter::EncodableValue& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 从 DPAPI 保护的文件读取或生成主密钥
  std::vector<uint8_t> GetOrCreateMasterKey();
};

#endif  // SECURITY_PLUGIN_H_
