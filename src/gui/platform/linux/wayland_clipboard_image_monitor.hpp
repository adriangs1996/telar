#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>

#pragma once

import telar.base.ds;
import telar.gui.foundation.core;
import telar.platform.primitives;

struct wl_display;

namespace telar::gui::platform {

  class WaylandClipboardImageMonitor {
  public:
    WaylandClipboardImageMonitor(ApplicationAllocator& memory, ::wl_display* display);
    ~WaylandClipboardImageMonitor();
    WaylandClipboardImageMonitor(const WaylandClipboardImageMonitor&) = delete;
    WaylandClipboardImageMonitor& operator=(const WaylandClipboardImageMonitor&) = delete;
    WaylandClipboardImageMonitor(WaylandClipboardImageMonitor&&) = delete;
    WaylandClipboardImageMonitor& operator=(WaylandClipboardImageMonitor&&) = delete;

    [[nodiscard]] bool available() const noexcept;
    [[nodiscard]] runtime::FileDescriptor capture();
    [[nodiscard]] bool acceptsLocalSelection(std::uint32_t seat_global) const noexcept;

  private:
    struct Native;
    ds::Box<Native, ApplicationAllocator> native_;
  };

}
