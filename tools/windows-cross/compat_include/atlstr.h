// Windows SDK 的 atlstr.h（ATL 字符串转换类）在 mingw-w64 里不存在 —— ATL 是
// MSVC/VS 专有组件，不随开源工具链分发。
//
// flutter_secure_storage_windows 只用到其中两个转换类：
//   CA2W：const char*  → 宽字符（供 CredReadW/CredDeleteW 的 LPCWSTR 参数）
//   CW2A：const wchar_t* → 窄字符（供 std::string 接收）
// 并且都通过 .m_psz 成员取值（ATL 的既有接口形态）。
//
// 这里按 ATL 的接口形状做一个等价实现，编解码用 Win32 的 UTF-8 ↔ UTF-16
// 转换（ATL 默认 CP_ACP；本插件的凭据名与 key 全为 ASCII，UTF-8 是更安全的
// 超集）。MSVC 上仍走真正的 atlstr.h。
#ifndef AI_TERMINAL_COMPAT_ATLSTR_H_
#define AI_TERMINAL_COMPAT_ATLSTR_H_

#include <string>
#include <vector>

#ifndef _WINDOWS_
#include <windows.h>
#endif

namespace ai_terminal_compat {

inline std::wstring narrowToWide(const char* s) {
  if (s == nullptr) {
    return std::wstring();
  }
  const int needed = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::vector<wchar_t> buf(static_cast<size_t>(needed));
  MultiByteToWideChar(CP_UTF8, 0, s, -1, buf.data(), needed);
  return std::wstring(buf.data());
}

inline std::string wideToNarrow(const wchar_t* s) {
  if (s == nullptr) {
    return std::string();
  }
  const int needed = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
  if (needed <= 0) {
    return std::string();
  }
  std::vector<char> buf(static_cast<size_t>(needed));
  WideCharToMultiByte(CP_UTF8, 0, s, -1, buf.data(), needed, nullptr, nullptr);
  return std::string(buf.data());
}

}  // namespace ai_terminal_compat

class CA2W {
 public:
  CA2W(const char* psz) : data_(ai_terminal_compat::narrowToWide(psz)) {
    m_psz = data_.empty() ? nullptr : &data_[0];
  }
  CA2W(const std::string& s) : data_(ai_terminal_compat::narrowToWide(s.c_str())) {
    m_psz = data_.empty() ? nullptr : &data_[0];
  }

  // ATL 的取值方式：m_psz。注意是非 const —— CREDENTIALW::TargetName 是
  // LPWSTR，需要能直接赋值（与 ATL 的 CA2W::m_psz 形态一致）。
  wchar_t* m_psz;

  operator const wchar_t*() const { return data_.c_str(); }
  const wchar_t* c_str() const { return data_.c_str(); }

 private:
  CA2W(const CA2W&) = delete;
  CA2W& operator=(const CA2W&) = delete;

  std::wstring data_;
};

class CW2A {
 public:
  CW2A(const wchar_t* psz) : data_(ai_terminal_compat::wideToNarrow(psz)) {
    m_psz = const_cast<char*>(data_.c_str());
  }
  CW2A(const std::wstring& s) : data_(ai_terminal_compat::wideToNarrow(s.c_str())) {
    m_psz = const_cast<char*>(data_.c_str());
  }

  char* m_psz;

  operator const char*() const { return data_.c_str(); }
  // 供 `std::string s = CW2A(...)` 这种 copy-init 使用
  operator std::string() const { return data_; }
  const char* c_str() const { return data_.c_str(); }

 private:
  CW2A(const CW2A&) = delete;
  CW2A& operator=(const CW2A&) = delete;

  std::string data_;
};

#endif  // AI_TERMINAL_COMPAT_ATLSTR_H_
