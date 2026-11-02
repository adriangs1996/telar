#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_source.hpp"

namespace telar::gui::platform {

class XcbClipboardImageMonitor {
public:
  explicit XcbClipboardImageMonitor(ApplicationAllocator &memory);
  ~XcbClipboardImageMonitor();
  XcbClipboardImageMonitor(const XcbClipboardImageMonitor &) = delete;
  XcbClipboardImageMonitor &operator=(const XcbClipboardImageMonitor &) = delete;
  XcbClipboardImageMonitor(XcbClipboardImageMonitor &&) = delete;
  XcbClipboardImageMonitor &operator=(XcbClipboardImageMonitor &&) = delete;

  void cancel() noexcept;

  [[nodiscard]] ClipboardImageSource capture();

private:
  struct Native;
  ApplicationAllocator &memory_;
  Owned<Native, ApplicationAllocator> native_;
};

}
