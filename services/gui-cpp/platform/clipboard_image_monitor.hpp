#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_source.hpp"
#ifdef __linux__
#include "platform/linux/xcb_clipboard_image_monitor.hpp"
#include <optional>
#endif

namespace telar::gui::platform {

class ClipboardImageMonitor {
public:
  explicit ClipboardImageMonitor(ApplicationAllocator &memory);
  ~ClipboardImageMonitor();
  ClipboardImageMonitor(const ClipboardImageMonitor &) = delete;
  ClipboardImageMonitor &operator=(const ClipboardImageMonitor &) = delete;
  ClipboardImageMonitor(ClipboardImageMonitor &&) = delete;
  ClipboardImageMonitor &operator=(ClipboardImageMonitor &&) = delete;

  void cancel() noexcept;

  [[nodiscard]] ClipboardImageSource snapshot();

private:
  struct Native;
  ApplicationAllocator &memory_;
  Owned<Native, ApplicationAllocator> native_;
#ifdef __linux__
  std::optional<XcbClipboardImageMonitor> xcb_;
#endif
};

}
