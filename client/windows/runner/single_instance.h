#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Registered window message that asks the running HomeBox instance to show
// its main window, even when it is hidden in the notification area.
UINT ShowInstanceMessage();

// Marks |window| as the main window of the running HomeBox instance so that a
// second launch can find it.
void MarkPrimaryInstanceWindow(HWND window);

// Removes the marker set by MarkPrimaryInstanceWindow.
void UnmarkPrimaryInstanceWindow(HWND window);

// Asks the already running instance to show its main window. Waits up to
// |timeout_ms| for that window to appear, because the first instance may still
// be starting up. Returns false when no window was found.
bool ActivatePrimaryInstance(DWORD timeout_ms);

#endif  // RUNNER_SINGLE_INSTANCE_H_
