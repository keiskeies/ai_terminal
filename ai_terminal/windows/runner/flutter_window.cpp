#include "flutter_window.h"

#include <optional>
#include <string>
#include <imm.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "security_util.h"

#pragma comment(lib, "imm32.lib")

// Flutter 3.47 Windows 引擎的 TextInput 有两处缺陷：IME 组字模型重复上屏
// （TextField 同样受影响）；attach 客户端后英文模式会吞掉 Ctrl+C/V 等编辑键。
// 因此 Windows 终端不 attach TextInput，改由这里子类化 Flutter 视图窗口：
// 拦截 WM_IME_* 把上屏串经 MethodChannel 交给 Dart；转发无键down 的 WM_CHAR
// （Unicode 注入）；用 ImmSetCandidateWindow 定位候选窗。
static WNDPROC g_original_view_proc = nullptr;
static flutter::MethodChannel<flutter::EncodableValue>* g_ime_channel = nullptr;
static bool g_terminal_focused = false;
static bool g_has_caret = false;
static double g_caret_x = 0;
static double g_caret_y = 0;
static bool g_keydown_seen = false;
static bool g_flush_timer = false;
static std::wstring g_pending_text;

static std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return {};
  }
  int n = WideCharToMultiByte(CP_UTF8, 0, wide.data(), (int)wide.size(),
                              nullptr, 0, nullptr, nullptr);
  std::string utf8(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), (int)wide.size(), utf8.data(), n,
                      nullptr, nullptr);
  return utf8;
}

static void FlushPendingText(HWND hwnd) {
  if (g_flush_timer) {
    KillTimer(hwnd, 1);
    g_flush_timer = false;
  }
  if (g_pending_text.empty()) {
    return;
  }
  std::string utf8 = Utf8FromWide(g_pending_text);
  g_pending_text.clear();
  if (g_ime_channel) {
    g_ime_channel->InvokeMethod(
        "text", std::make_unique<flutter::EncodableValue>(utf8));
  }
}

static LRESULT CALLBACK ImeViewProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  switch (message) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      // VK_PACKET 是 SendInput Unicode 注入伴随的 keydown，不算物理键，
      // 否则紧随的 WM_CHAR 被误判为键down 派生而交给引擎丢弃。
      if (wparam != VK_PACKET) {
        g_keydown_seen = true;
      }
      FlushPendingText(hwnd);
      break;
    case WM_CHAR:
      // 有键down 的 WM_CHAR 走引擎键事件路径；孤儿 WM_CHAR 是 Unicode 注入
      // （SendInput KEYEVENTF_UNICODE），引擎无客户端时会丢弃，这里转发 Dart。
      if (g_keydown_seen) {
        g_keydown_seen = false;
        break;
      }
      if (!g_terminal_focused) {
        break;
      }
      g_pending_text.push_back((wchar_t)wparam);
      if (!g_flush_timer) {
        SetTimer(hwnd, 1, 30, nullptr);
        g_flush_timer = true;
      }
      return 0;
    case WM_TIMER:
      if (wparam == 1) {
        FlushPendingText(hwnd);
        return 0;
      }
      break;
    case WM_IME_STARTCOMPOSITION: {
      if (!g_terminal_focused) {
        break;
      }
      if (g_has_caret) {
        HIMC himc = ImmGetContext(hwnd);
        if (himc) {
          double scale = GetDpiForWindow(hwnd) / 96.0;
          CANDIDATEFORM form = {};
          form.dwIndex = 0;
          form.dwStyle = CFS_POINT;
          form.ptCurrentPos = {(LONG)(g_caret_x * scale),
                               (LONG)(g_caret_y * scale)};
          ImmSetCandidateWindow(himc, &form);
          ImmReleaseContext(hwnd, himc);
        }
      }
      return 0;
    }
    case WM_IME_ENDCOMPOSITION:
    case WM_IME_CHAR:
      if (!g_terminal_focused) {
        break;
      }
      return 0;
    case WM_IME_COMPOSITION: {
      if (!g_terminal_focused) {
        break;
      }
      if (lparam & GCS_RESULTSTR) {
        HIMC himc = ImmGetContext(hwnd);
        if (himc) {
          LONG bytes = ImmGetCompositionStringW(himc, GCS_RESULTSTR, nullptr, 0);
          if (bytes > 0) {
            std::wstring wide(bytes / sizeof(wchar_t), L'\0');
            ImmGetCompositionStringW(himc, GCS_RESULTSTR, wide.data(), bytes);
            if (g_ime_channel) {
              g_ime_channel->InvokeMethod(
                  "commit",
                  std::make_unique<flutter::EncodableValue>(Utf8FromWide(wide)));
            }
          }
          ImmReleaseContext(hwnd, himc);
        }
      }
      return 0;
    }
    default:
      g_keydown_seen = false;
      FlushPendingText(hwnd);
      break;
  }
  return CallWindowProc(g_original_view_proc, hwnd, message, wparam, lparam);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // 注册安全 MethodChannel（DPAPI 主密钥管理）
  // 直接用 engine messenger 创建 channel，不走 plugin 注册机制
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            flutter_controller_->engine()->messenger(),
            "com.keiskei.aiterminal/security",
            &flutter::StandardMethodCodec::GetInstance());

    channel->SetMethodCallHandler(
        [](const flutter::MethodCall<flutter::EncodableValue>& call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
               result) {
          if (call.method_name() == "getMasterKey") {
            auto key = GetOrCreateMasterKey();
            if (!key.empty()) {
              result->Success(flutter::EncodableValue(key));
            } else {
              result->Error("KEY_ERROR", "Failed to get or create master key");
            }
          } else {
            result->NotImplemented();
          }
        });
  }

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 安装 IME 拦截（见文件头部注释）。静态 channel 生命周期与引擎一致。
  {
    static flutter::MethodChannel<flutter::EncodableValue> ime_channel(
        flutter_controller_->engine()->messenger(),
        "com.keiskei.aiterminal/ime",
        &flutter::StandardMethodCodec::GetInstance());
    g_ime_channel = &ime_channel;
    ime_channel.SetMethodCallHandler(
        [](const flutter::MethodCall<flutter::EncodableValue>& call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
               result) {
          if (call.method_name() == "focus") {
            g_terminal_focused = std::get<bool>(*call.arguments());
            result->Success();
          } else if (call.method_name() == "setCaretRect") {
            const auto& map =
                std::get<flutter::EncodableMap>(*call.arguments());
            g_caret_x = std::get<double>(map.at(flutter::EncodableValue("x")));
            g_caret_y = std::get<double>(map.at(flutter::EncodableValue("y")));
            g_has_caret = true;
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
    HWND view = flutter_controller_->view()->GetNativeWindow();
    g_original_view_proc =
        (WNDPROC)SetWindowLongPtr(view, GWLP_WNDPROC, (LONG_PTR)ImeViewProc);
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
