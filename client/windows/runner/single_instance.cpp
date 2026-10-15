#include "single_instance.h"

namespace {

constexpr wchar_t kShowInstanceMessageName[] =
    L"HomeBox-ShowInstance-6A91B2E5-257E-44B9-A9F2-B1E1C4533D90";
// Window property names are global atoms, so GetProp works across processes.
constexpr wchar_t kPrimaryWindowProperty[] =
    L"HomeBox-PrimaryWindow-6A91B2E5-257E-44B9-A9F2-B1E1C4533D90";
constexpr DWORD kPollIntervalMs = 100;

BOOL CALLBACK FindPrimaryWindow(HWND window, LPARAM found) {
  if (GetPropW(window, kPrimaryWindowProperty) == nullptr) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(found) = window;
  return FALSE;
}

}  // namespace

UINT ShowInstanceMessage() {
  static const UINT message = RegisterWindowMessageW(kShowInstanceMessageName);
  return message;
}

void MarkPrimaryInstanceWindow(HWND window) {
  SetPropW(window, kPrimaryWindowProperty, reinterpret_cast<HANDLE>(1));
  // The message carries no payload, so accepting it from a process with a
  // lower integrity level (e.g. when this instance runs elevated) is safe.
  ChangeWindowMessageFilterEx(window, ShowInstanceMessage(), MSGFLT_ALLOW,
                              nullptr);
}

void UnmarkPrimaryInstanceWindow(HWND window) {
  RemovePropW(window, kPrimaryWindowProperty);
}

bool ActivatePrimaryInstance(DWORD timeout_ms) {
  const UINT message = ShowInstanceMessage();
  if (message == 0) return false;
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    HWND window = nullptr;
    EnumWindows(FindPrimaryWindow, reinterpret_cast<LPARAM>(&window));
    if (window != nullptr) {
      // This process was just launched by the user and owns the foreground
      // right; hand it over so the running instance can activate its window.
      DWORD process_id = 0;
      GetWindowThreadProcessId(window, &process_id);
      if (process_id != 0) AllowSetForegroundWindow(process_id);
      return PostMessageW(window, message, 0, 0) != FALSE;
    }
    if (GetTickCount64() >= deadline) return false;
    Sleep(kPollIntervalMs);
  }
}
