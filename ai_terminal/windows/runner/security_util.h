#ifndef SECURITY_UTIL_H_
#define SECURITY_UTIL_H_

#include <cstdint>
#include <vector>

// Windows DPAPI 安全工具（不依赖 Flutter 头文件）
// 主密钥用 CryptProtectData 加密后存文件，绑定当前 Windows 用户账户
// 换用户或换机器无法解密

// 从 DPAPI 保护的文件读取或生成 32 字节主密钥
std::vector<uint8_t> GetOrCreateMasterKey();

#endif  // SECURITY_UTIL_H_
