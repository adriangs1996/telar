#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/file_descriptor.hpp"
#include <cstdint>

struct wl_display;

namespace telar::gui::platform {

class WaylandClipboardImageMonitor {
public:
  WaylandClipboardImageMonitor(ApplicationAllocator &memory, ::wl_display *display);
  ~WaylandClipboardImageMonitor();
  WaylandClipboardImageMonitor(const WaylandClipboardImageMonitor &) = delete;
  WaylandClipboardImageMonitor &operator=(const WaylandClipboardImageMonitor &) = delete;
  WaylandClipboardImageMonitor(WaylandClipboardImageMonitor &&) = delete;
  WaylandClipboardImageMonitor &operator=(WaylandClipboardImageMonitor &&) = delete;

  [[nodiscard]] bool available() const noexcept;
  [[nodiscard]] runtime::FileDescriptor capture();
  [[nodiscard]] bool acceptsLocalSelection(std::uint32_t seat_global) const noexcept;

private:
  struct Native;
  Owned<Native, ApplicationAllocator> native_;
};

}
