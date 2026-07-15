#include "security_util.h"

#include <windows.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <string>
#include <fstream>

#pragma comment(lib, "Crypt32.lib")

namespace {

// 获取密钥文件路径：%APPDATA%/ai_terminal/masterkey.bin
std::wstring GetKeyFilePath() {
  PWSTR app_data_path = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                     &app_data_path))) {
    std::wstring path(app_data_path);
    CoTaskMemFree(app_data_path);
    path += L"\\ai_terminal";
    CreateDirectoryW(path.c_str(), nullptr);
    path += L"\\masterkey.bin";
    return path;
  }
  return L"masterkey.bin";
}

// DPAPI 加密
std::vector<uint8_t> ProtectData(const uint8_t* data, size_t len) {
  DATA_BLOB input;
  input.cbData = static_cast<DWORD>(len);
  input.pbData = const_cast<BYTE*>(data);
  DATA_BLOB output;

  if (CryptProtectData(&input, L"MasterKey", nullptr, nullptr, nullptr,
                       CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    std::vector<uint8_t> result(output.pbData, output.pbData + output.cbData);
    LocalFree(output.pbData);
    return result;
  }
  return {};
}

// DPAPI 解密
std::vector<uint8_t> UnprotectData(const uint8_t* data, size_t len) {
  DATA_BLOB input;
  input.cbData = static_cast<DWORD>(len);
  input.pbData = const_cast<BYTE*>(data);
  DATA_BLOB output;

  if (CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    std::vector<uint8_t> result(output.pbData, output.pbData + output.cbData);
    LocalFree(output.pbData);
    return result;
  }
  return {};
}

// 生成 32 字节随机密钥
std::vector<uint8_t> GenerateRandomKey() {
  std::vector<uint8_t> key(32);
  HCRYPTPROV hProv = 0;
  if (CryptAcquireContextW(&hProv, nullptr, nullptr, PROV_RSA_FULL,
                           CRYPT_VERIFYCONTEXT)) {
    CryptGenRandom(hProv, 32, key.data());
    CryptReleaseContext(hProv, 0);
  } else {
    // 极端回退：用时间戳
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    srand(static_cast<unsigned>(counter.QuadPart % UINT_MAX));
    for (int i = 0; i < 32; i++) {
      key[i] = static_cast<uint8_t>(rand() & 0xFF);
    }
  }
  return key;
}

}  // namespace

std::vector<uint8_t> GetOrCreateMasterKey() {
  auto key_path = GetKeyFilePath();

  // 1. 尝试读取已存在的密钥文件
  std::ifstream file(key_path, std::ios::binary);
  if (file) {
    std::vector<uint8_t> encrypted(
        (std::istreambuf_iterator<char>(file)),
        std::istreambuf_iterator<char>());
    file.close();

    if (!encrypted.empty()) {
      // DPAPI 解密
      auto decrypted = UnprotectData(encrypted.data(), encrypted.size());
      if (decrypted.size() == 32) {
        return decrypted;
      }
    }
  }

  // 2. 生成新密钥
  auto key = GenerateRandomKey();

  // 3. DPAPI 加密后写入文件
  auto protected_key = ProtectData(key.data(), key.size());
  if (!protected_key.empty()) {
    std::ofstream out(key_path, std::ios::binary);
    if (out) {
      out.write(reinterpret_cast<const char*>(protected_key.data()),
                protected_key.size());
      out.close();
    }
  }

  return key;
}
