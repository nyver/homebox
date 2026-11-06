#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <windows.h>
#include <ole2.h>

#include <functional>
#include <string>
#include <vector>

// An OLE drop target for files dragged from Explorer. Unlike WM_DROPFILES it
// reports the drag entering, moving over, and leaving the window, so the
// app can highlight where the files would go before they are dropped.
// Positions are in physical pixels relative to |window|'s client area.
class DropTarget : public IDropTarget {
 public:
  struct Callbacks {
    // A file drag entered or moved; |x|, |y| are client pixels.
    std::function<void(int x, int y)> on_hover;
    // The drag left the window or was cancelled.
    std::function<void()> on_leave;
    // Files were dropped at |x|, |y|.
    std::function<void(std::vector<std::wstring> paths, int x, int y)> on_drop;
  };

  DropTarget(HWND window, Callbacks callbacks);

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override;

 private:
  virtual ~DropTarget() = default;
  POINT ToClient(POINTL point) const;

  HWND window_;
  Callbacks callbacks_;
  LONG references_ = 1;
  // Whether the current drag carries files; anything else is refused.
  bool accepts_ = false;
  POINT last_point_{-1, -1};
};

#endif  // RUNNER_DROP_TARGET_H_
