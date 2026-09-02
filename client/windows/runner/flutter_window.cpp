#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayShowCommand = 1;
constexpr UINT kTrayOpenSyncFolderCommand = 2;
constexpr UINT kTrayExitCommand = 3;
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"HomeBox";

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()), nullptr,
                                         0, nullptr, nullptr);
  if (length == 0) return {};
  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length,
                      nullptr, nullptr);
  return result;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (length == 0) return {};
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

}  // namespace

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
  ConfigurePlatformChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // A notification-area policy may block icon registration. The main window
  // must remain usable in that case instead of failing the entire startup.
  AddTrayIcon();
  return true;
}

void FlutterWindow::OnDestroy() {
  DragAcceptFiles(GetHandle(), FALSE);
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DROPFILES) {
    HandleFileDrop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }

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
    case WM_CLOSE:
      // Closing the desktop window keeps HomeBox alive in the notification
      // area. Exit remains explicit in the tray context menu.
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    case kTrayCallbackMessage:
      if (lparam == WM_LBUTTONUP) {
        ShowFromTray();
      } else if (lparam == WM_RBUTTONUP) {
        HMENU menu = CreatePopupMenu();
        if (menu != nullptr) {
          AppendMenu(menu, MF_STRING, kTrayShowCommand, L"Show HomeBox");
          AppendMenu(menu,
                     MF_STRING |
                         (HasOpenableSyncFolder() ? MF_ENABLED : MF_GRAYED),
                     kTrayOpenSyncFolderCommand, L"Open sync folder");
          AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
          AppendMenu(menu, MF_STRING, kTrayExitCommand, L"Exit");
          POINT cursor;
          GetCursorPos(&cursor);
          SetForegroundWindow(hwnd);
          TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd,
                         nullptr);
          DestroyMenu(menu);
        }
      }
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == kTrayShowCommand) {
        ShowFromTray();
        return 0;
      }
      if (LOWORD(wparam) == kTrayOpenSyncFolderCommand) {
        OpenSyncFolder();
        return 0;
      }
      if (LOWORD(wparam) == kTrayExitCommand) {
        DestroyWindow(hwnd);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandleFileDrop(HDROP drop) {
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList paths;
  for (UINT index = 0; index < count; index++) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) continue;
    std::vector<wchar_t> path(length + 1);
    if (DragQueryFileW(drop, index, path.data(),
                       static_cast<UINT>(path.size())) == 0) {
      continue;
    }
    const std::string utf8_path = Utf8FromWide(path.data());
    if (!utf8_path.empty()) paths.emplace_back(utf8_path);
  }
  DragFinish(drop);
  if (paths.empty() || !platform_channel_) return;
  platform_channel_->InvokeMethod(
      "filesDropped",
      std::make_unique<flutter::EncodableValue>(std::move(paths)));
}

bool FlutterWindow::AddTrayIcon() {
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = LoadIcon(GetModuleHandle(nullptr),
                              MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"HomeBox");
  tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) == TRUE;
  return tray_icon_added_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

bool FlutterWindow::HasOpenableSyncFolder() const {
  if (sync_folder_path_.empty()) return false;
  const DWORD attributes = GetFileAttributes(sync_folder_path_.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

bool FlutterWindow::OpenSyncFolder() {
  if (!HasOpenableSyncFolder()) return false;
  return reinterpret_cast<intptr_t>(
             ShellExecute(GetHandle(), L"open", sync_folder_path_.c_str(),
                          nullptr, nullptr, SW_SHOWNORMAL)) >
         32;
}

bool FlutterWindow::OpenFileLocation(const std::wstring& file_path) {
  if (file_path.empty()) return false;
  const DWORD attributes = GetFileAttributes(file_path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return false;
  }

  const std::wstring arguments = L"/select,\"" + file_path + L"\"";
  return reinterpret_cast<intptr_t>(
             ShellExecute(GetHandle(), L"open", L"explorer.exe",
                          arguments.c_str(), nullptr, SW_SHOWNORMAL)) >
         32;
}

void FlutterWindow::ConfigurePlatformChannel() {
  platform_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "homebox/windows",
      &flutter::StandardMethodCodec::GetInstance());
  platform_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getAutostart") {
          result->Success(flutter::EncodableValue(IsAutostartEnabled()));
          return;
        }
        if (call.method_name() == "setAutostart") {
          const auto* enabled = call.arguments() == nullptr
                                    ? nullptr
                                    : std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("invalid-argument", "Expected a boolean enabled value.");
            return;
          }
          if (!SetAutostartEnabled(*enabled)) {
            result->Error("registry-error", "Could not update Windows autostart.");
            return;
          }
          result->Success(flutter::EncodableValue(*enabled));
          return;
        }
        if (call.method_name() == "setSyncFolder") {
          const auto* path = call.arguments() == nullptr
                                 ? nullptr
                                 : std::get_if<std::string>(call.arguments());
          if (path == nullptr) {
            result->Error("invalid-argument", "Expected a UTF-8 folder path.");
            return;
          }
          const std::wstring wide_path = WideFromUtf8(*path);
          if (!path->empty() && wide_path.empty()) {
            result->Error("invalid-argument", "Folder path is not valid UTF-8.");
            return;
          }
          sync_folder_path_ = wide_path;
          result->Success();
          return;
        }
        if (call.method_name() == "openSyncFolder") {
          result->Success(flutter::EncodableValue(OpenSyncFolder()));
          return;
        }
        if (call.method_name() == "openFileLocation") {
          const auto* path = call.arguments() == nullptr
                                 ? nullptr
                                 : std::get_if<std::string>(call.arguments());
          if (path == nullptr) {
            result->Error("invalid-argument", "Expected a UTF-8 file path.");
            return;
          }
          const std::wstring wide_path = WideFromUtf8(*path);
          if (path->empty() || wide_path.empty()) {
            result->Error("invalid-argument", "File path is not valid UTF-8.");
            return;
          }
          result->Success(flutter::EncodableValue(OpenFileLocation(wide_path)));
          return;
        }
        result->NotImplemented();
      });
}

bool FlutterWindow::IsAutostartEnabled() const {
  DWORD value_type = 0;
  wchar_t value[MAX_PATH]{};
  DWORD value_size = sizeof(value);
  return RegGetValue(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                     &value_type, value, &value_size) == ERROR_SUCCESS;
}

bool FlutterWindow::SetAutostartEnabled(bool enabled) const {
  if (!enabled) {
    const LONG status = RegDeleteKeyValue(HKEY_CURRENT_USER, kRunKey, kRunValue);
    return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
  }
  wchar_t path[MAX_PATH]{};
  const DWORD length = GetModuleFileName(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return false;
  const std::wstring command = L"\"" + std::wstring(path) + L"\"";
  return RegSetKeyValue(HKEY_CURRENT_USER, kRunKey, kRunValue, REG_SZ,
                        command.c_str(),
                        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}
