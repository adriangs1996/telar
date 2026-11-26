#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#ifdef __linux__
#include "platform/linux/wayland_clipboard_image_monitor.hpp"
#include "platform/linux/xcb_clipboard_image_monitor.hpp"
#endif

#pragma once

import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;

namespace telar::gui::platform {

  class ClipboardImageMonitor {
  public:
#ifdef __linux__
    explicit ClipboardImageMonitor(ApplicationAllocator& memory);
    ~ClipboardImageMonitor();
    void cancel() noexcept;
    [[nodiscard]] ClipboardImageSource snapshot();
#else
    explicit ClipboardImageMonitor(ApplicationAllocator& memory) noexcept
        : memory_(memory) {}

    ~ClipboardImageMonitor() = default;

    void cancel() noexcept {}

    [[nodiscard]] ClipboardImageSource snapshot() {
      return ClipboardImageSource::snapshot(memory_);
    }
#endif
    ClipboardImageMonitor(const ClipboardImageMonitor&) = delete;
    ClipboardImageMonitor& operator=(const ClipboardImageMonitor&) = delete;
    ClipboardImageMonitor(ClipboardImageMonitor&&) = delete;
    ClipboardImageMonitor& operator=(ClipboardImageMonitor&&) = delete;

  private:
    ApplicationAllocator& memory_;
#ifdef __linux__
    WaylandClipboardImageMonitor native_;
    ds::Option<XcbClipboardImageMonitor> xcb_;
#endif
  };

}
