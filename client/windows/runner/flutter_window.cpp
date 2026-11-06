#include "flutter_window.h"

#include <cwctype>
#include <optional>
#include <shellapi.h>
#include <shlwapi.h>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/encodable_value.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"
#include "single_instance.h"

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

// Extensions that Windows would execute, install, mount, or otherwise treat
// as active content rather than open in a viewer. A synced file with one of
// these must never be launched by a plain tap; the caller falls back to
// "Save as" instead. The explicit list covers types Windows does not always
// flag; AssocIsDangerous adds the system's own Attachment Manager list,
// including types registered later by installed software.
bool IsExecutableExtension(const std::wstring& path) {
  const std::wstring::size_type dot = path.find_last_of(L'.');
  const std::wstring::size_type separator = path.find_last_of(L"\\/");
  if (dot == std::wstring::npos ||
      (separator != std::wstring::npos && dot < separator)) {
    return false;
  }
  std::wstring extension = path.substr(dot);
  for (wchar_t& c : extension) c = static_cast<wchar_t>(std::towlower(c));
  static const wchar_t* const kBlocked[] = {
      // Programs, installers, and packages.
      L".exe", L".com", L".scr", L".pif", L".msi", L".msp", L".mst",
      L".appx", L".appxbundle", L".msix", L".msixbundle", L".application",
      L".appref-ms", L".gadget", L".cpl", L".msc", L".diagcab", L".xll",
      // Scripts and script hosts.
      L".bat", L".cmd", L".ps1", L".ps1xml", L".ps2", L".ps2xml", L".psc1",
      L".psc2", L".psd1", L".psm1", L".vb", L".vbs", L".vbe", L".js",
      L".jse", L".ws", L".wsf", L".wsc", L".wsh", L".hta", L".sct",
      L".py", L".pyw", L".pyc", L".pyz", L".jar", L".inf", L".reg",
      // Shortcuts and shell links that launch another target.
      L".lnk", L".url", L".website", L".scf", L".library-ms",
      L".searchconnector-ms", L".search-ms", L".settingcontent-ms",
      // Compiled help and disk images that bypass Mark-of-the-Web.
      L".chm", L".hlp", L".iso", L".img", L".vhd", L".vhdx"};
  for (const wchar_t* blocked : kBlocked) {
    if (extension == blocked) return true;
  }
  return AssocIsDangerous(extension.c_str()) != FALSE;
}

// The string stored under |key| in a method-call argument map, or nullptr
// when it is missing or not a string.
const std::string* StringArgument(const flutter::EncodableMap& args,
                                  const char* key) {
  const auto entry = args.find(flutter::EncodableValue(key));
  return entry == args.end() ? nullptr
                             : std::get_if<std::string>(&entry->second);
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
  RegisterFileDropTarget();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // A notification-area policy may block icon registration. The main window
  // must remain usable in that case instead of failing the entire startup.
  taskbar_created_message_ = RegisterWindowMessage(L"TaskbarCreated");
  AddTrayIcon();
  MarkPrimaryInstanceWindow(GetHandle());
  return true;
}

void FlutterWindow::OnDestroy() {
  RevokeFileDropTarget();
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
  if (message == WM_DESTROY) {
    // OnDestroy runs after the base class has dropped the window handle, so
    // the property must be removed here while |hwnd| is still valid.
    UnmarkPrimaryInstanceWindow(hwnd);
  }
  if (message != 0 && message == ShowInstanceMessage()) {
    ShowFromTray();
    return 0;
  }
  if (message != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
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
      if (lparam == WM_LBUTTONUP || lparam == NIN_BALLOONUSERCLICK) {
        ShowFromTray();
      } else if (lparam == WM_RBUTTONUP) {
        HMENU menu = CreatePopupMenu();
        if (menu != nullptr) {
          AppendMenu(menu, MF_STRING, kTrayShowCommand,
                     tray_show_label_.c_str());
          AppendMenu(menu,
                     MF_STRING |
                         (HasOpenableSyncFolder() ? MF_ENABLED : MF_GRAYED),
                     kTrayOpenSyncFolderCommand,
                     tray_open_folder_label_.c_str());
          AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
          AppendMenu(menu, MF_STRING, kTrayExitCommand,
                     tray_exit_label_.c_str());
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
  // WM_DROPFILES carries no useful position: drop into the open folder.
  SendDroppedFiles(std::move(paths), -1, -1);
}

void FlutterWindow::SendDroppedFiles(flutter::EncodableList paths, int x,
                                     int y) {
  if (paths.empty() || !platform_channel_) return;
  flutter::EncodableMap args{
      {flutter::EncodableValue("paths"),
       flutter::EncodableValue(std::move(paths))},
      {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
      {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
  };
  platform_channel_->InvokeMethod(
      "filesDropped",
      std::make_unique<flutter::EncodableValue>(std::move(args)));
}

void FlutterWindow::RegisterFileDropTarget() {
  HWND view = flutter_controller_->view()->GetNativeWindow();
  DropTarget::Callbacks callbacks;
  callbacks.on_hover = [this](int x, int y) {
    if (!platform_channel_) return;
    platform_channel_->InvokeMethod(
        "fileDragHover",
        std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
            {flutter::EncodableValue("x"), flutter::EncodableValue(x)},
            {flutter::EncodableValue("y"), flutter::EncodableValue(y)},
        }));
  };
  callbacks.on_leave = [this]() {
    if (platform_channel_) platform_channel_->InvokeMethod("fileDragExit", nullptr);
  };
  callbacks.on_drop = [this](std::vector<std::wstring> paths, int x, int y) {
    flutter::EncodableList encoded;
    for (const std::wstring& path : paths) {
      const std::string utf8_path = Utf8FromWide(path);
      if (!utf8_path.empty()) encoded.emplace_back(utf8_path);
    }
    if (encoded.empty()) {
      if (platform_channel_) {
        platform_channel_->InvokeMethod("fileDragExit", nullptr);
      }
      return;
    }
    SendDroppedFiles(std::move(encoded), x, y);
  };
  auto* target = new DropTarget(view, std::move(callbacks));
  if (RegisterDragDrop(view, target) == S_OK) {
    // RegisterDragDrop holds its own reference; this one is released on
    // revocation.
    drop_target_ = target;
    drop_target_window_ = view;
    return;
  }
  target->Release();
  // Fall back to plain drops without hover feedback.
  DragAcceptFiles(GetHandle(), TRUE);
}

void FlutterWindow::RevokeFileDropTarget() {
  if (drop_target_ == nullptr) {
    DragAcceptFiles(GetHandle(), FALSE);
    return;
  }
  RevokeDragDrop(drop_target_window_);
  drop_target_->Release();
  drop_target_ = nullptr;
  drop_target_window_ = nullptr;
}

bool FlutterWindow::AddTrayIcon() {
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = LoadIcon(GetModuleHandle(nullptr),
                              MAKEINTRESOURCE(IDI_APP_ICON));
  if (tray_icon_.szTip[0] == L'\0') wcscpy_s(tray_icon_.szTip, L"HomeBox");
  tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) == TRUE;
  return tray_icon_added_;
}

void FlutterWindow::SetTrayStatus(const std::wstring& tooltip) {
  // szTip holds at most 127 characters plus the terminator.
  wcsncpy_s(tray_icon_.szTip, tooltip.c_str(), _TRUNCATE);
  if (!tray_icon_added_) return;
  tray_icon_.uFlags = NIF_TIP;
  Shell_NotifyIcon(NIM_MODIFY, &tray_icon_);
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
}

void FlutterWindow::ShowTrayNotification(const std::wstring& title,
                                         const std::wstring& body) {
  if (!tray_icon_added_) return;
  NOTIFYICONDATA notification = tray_icon_;
  notification.uFlags = NIF_INFO;
  wcsncpy_s(notification.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(notification.szInfo, body.c_str(), _TRUNCATE);
  // Focus assist and quiet hours are respected; the user can click the
  // notification to bring the window back (NIN_BALLOONUSERCLICK).
  notification.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  Shell_NotifyIcon(NIM_MODIFY, &notification);
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  HWND window = GetHandle();
  // SW_RESTORE would un-maximize a hidden maximized window; only use it when
  // the window is actually minimized.
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window);
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

  const std::wstring::size_type separator = file_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return false;
  const std::wstring folder_path =
      separator == 2 && file_path.size() > 2 && file_path[1] == L':'
          ? file_path.substr(0, 3)
          : file_path.substr(0, separator);
  if (folder_path.empty()) return false;
  return reinterpret_cast<intptr_t>(
             ShellExecute(GetHandle(), L"open", folder_path.c_str(), nullptr,
                          nullptr, SW_SHOWNORMAL)) >
         32;
}

bool FlutterWindow::OpenFile(const std::wstring& file_path) {
  if (file_path.empty()) return false;
  std::wstring path = file_path;
  for (wchar_t& c : path) {
    if (c == L'/') c = L'\\';
  }
  const DWORD attributes = GetFileAttributes(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      IsExecutableExtension(path)) {
    return false;
  }
  // The "open" verb uses the user's default application. When none is
  // associated (SE_ERR_NOASSOC), "openas" shows Windows' own app chooser.
  intptr_t result = reinterpret_cast<intptr_t>(ShellExecute(
      GetHandle(), L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
  if (result == SE_ERR_NOASSOC) {
    result = reinterpret_cast<intptr_t>(ShellExecute(
        GetHandle(), L"openas", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
  }
  return result > 32;
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
        if (call.method_name() == "setTrayStatus") {
          const auto* args = call.arguments() == nullptr
                                 ? nullptr
                                 : std::get_if<flutter::EncodableMap>(
                                       call.arguments());
          if (args == nullptr) {
            result->Error("invalid-argument", "Expected a status map.");
            return;
          }
          const auto text = [args](const char* key) -> std::wstring {
            const std::string* value = StringArgument(*args, key);
            return value == nullptr ? std::wstring() : WideFromUtf8(*value);
          };
          const std::wstring tooltip = text("tooltip");
          const std::wstring show = text("show");
          const std::wstring open_folder = text("openFolder");
          const std::wstring exit = text("exit");
          if (!show.empty()) tray_show_label_ = show;
          if (!open_folder.empty()) tray_open_folder_label_ = open_folder;
          if (!exit.empty()) tray_exit_label_ = exit;
          if (!tooltip.empty()) SetTrayStatus(tooltip);
          result->Success();
          return;
        }
        if (call.method_name() == "showNotification") {
          const auto* args = call.arguments() == nullptr
                                 ? nullptr
                                 : std::get_if<flutter::EncodableMap>(
                                       call.arguments());
          const std::string* title =
              args == nullptr ? nullptr : StringArgument(*args, "title");
          const std::string* body =
              args == nullptr ? nullptr : StringArgument(*args, "body");
          if (title == nullptr || body == nullptr) {
            result->Error("invalid-argument", "Expected a title and a body.");
            return;
          }
          ShowTrayNotification(WideFromUtf8(*title), WideFromUtf8(*body));
          result->Success();
          return;
        }
        if (call.method_name() == "openSyncFolder") {
          result->Success(flutter::EncodableValue(OpenSyncFolder()));
          return;
        }
        if (call.method_name() == "openFile") {
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
          result->Success(flutter::EncodableValue(OpenFile(wide_path)));
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
