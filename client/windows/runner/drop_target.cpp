#include "drop_target.h"

#include <shellapi.h>

namespace {

FORMATETC FileDropFormat() {
  return FORMATETC{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool CarriesFiles(IDataObject* data) {
  if (data == nullptr) return false;
  FORMATETC format = FileDropFormat();
  return data->QueryGetData(&format) == S_OK;
}

}  // namespace

DropTarget::DropTarget(HWND window, Callbacks callbacks)
    : window_(window), callbacks_(std::move(callbacks)) {}

HRESULT DropTarget::QueryInterface(REFIID riid, void** object) {
  if (object == nullptr) return E_POINTER;
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG DropTarget::AddRef() { return InterlockedIncrement(&references_); }

ULONG DropTarget::Release() {
  const ULONG remaining = InterlockedDecrement(&references_);
  if (remaining == 0) delete this;
  return remaining;
}

POINT DropTarget::ToClient(POINTL point) const {
  POINT client{point.x, point.y};
  ScreenToClient(window_, &client);
  return client;
}

HRESULT DropTarget::DragEnter(IDataObject* data, DWORD, POINTL point,
                              DWORD* effect) {
  accepts_ = CarriesFiles(data);
  last_point_ = POINT{-1, -1};
  return DragOver(0, point, effect);
}

HRESULT DropTarget::DragOver(DWORD, POINTL point, DWORD* effect) {
  if (effect == nullptr) return E_INVALIDARG;
  if (!accepts_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  // Uploading reads the files; it never moves them out of their folder.
  *effect = DROPEFFECT_COPY;
  const POINT client = ToClient(point);
  // DragOver repeats while the mouse rests; only report real movement.
  if ((client.x != last_point_.x || client.y != last_point_.y) &&
      callbacks_.on_hover) {
    last_point_ = client;
    callbacks_.on_hover(client.x, client.y);
  }
  return S_OK;
}

HRESULT DropTarget::DragLeave() {
  if (accepts_ && callbacks_.on_leave) callbacks_.on_leave();
  accepts_ = false;
  return S_OK;
}

HRESULT DropTarget::Drop(IDataObject* data, DWORD, POINTL point,
                         DWORD* effect) {
  if (effect != nullptr) *effect = DROPEFFECT_NONE;
  const bool accepted = accepts_;
  accepts_ = false;
  if (!accepted || data == nullptr) {
    if (callbacks_.on_leave) callbacks_.on_leave();
    return S_OK;
  }
  FORMATETC format = FileDropFormat();
  STGMEDIUM medium{};
  if (data->GetData(&format, &medium) != S_OK) {
    if (callbacks_.on_leave) callbacks_.on_leave();
    return S_OK;
  }
  std::vector<std::wstring> paths;
  HDROP drop = static_cast<HDROP>(GlobalLock(medium.hGlobal));
  if (drop != nullptr) {
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT index = 0; index < count; index++) {
      const UINT length = DragQueryFileW(drop, index, nullptr, 0);
      if (length == 0) continue;
      std::wstring path(length + 1, L'\0');
      if (DragQueryFileW(drop, index, path.data(),
                         static_cast<UINT>(path.size())) == 0) {
        continue;
      }
      path.resize(length);
      paths.push_back(std::move(path));
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  if (effect != nullptr) *effect = DROPEFFECT_COPY;
  const POINT client = ToClient(point);
  if (callbacks_.on_drop) {
    callbacks_.on_drop(std::move(paths), client.x, client.y);
  }
  return S_OK;
}
