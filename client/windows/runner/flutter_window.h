#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool AddTrayIcon();
  void RemoveTrayIcon();
  void SetTrayStatus(const std::wstring& tooltip);
  void ShowTrayNotification(const std::wstring& title,
                            const std::wstring& body);
  void ShowFromTray();
  bool HasOpenableSyncFolder() const;
  bool OpenSyncFolder();
  bool OpenFile(const std::wstring& file_path);
  bool OpenFileLocation(const std::wstring& file_path);
  void ConfigurePlatformChannel();
  void HandleFileDrop(HDROP drop);
  bool IsAutostartEnabled() const;
  bool SetAutostartEnabled(bool enabled) const;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      platform_channel_;
  NOTIFYICONDATA tray_icon_{};
  bool tray_icon_added_ = false;
  std::wstring sync_folder_path_;
  // Tray menu labels in the app's language; set from Dart.
  std::wstring tray_show_label_ = L"Show HomeBox";
  std::wstring tray_open_folder_label_ = L"Open sync folder";
  std::wstring tray_exit_label_ = L"Exit";
  // Sent by Explorer when the taskbar is recreated (e.g. after a crash),
  // which drops every notification-area icon.
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
