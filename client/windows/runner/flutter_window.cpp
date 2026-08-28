#include "flutter_window.h"

#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayShowCommand = 1;
constexpr UINT kTrayExitCommand = 2;

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
