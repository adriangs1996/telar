#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_source.hpp"

namespace telar::gui::platform {

class ClipboardImageMonitor {
public:
  explicit ClipboardImageMonitor(ApplicationAllocator &memory);
  ~ClipboardImageMonitor();
  ClipboardImageMonitor(const ClipboardImageMonitor &) = delete;
  ClipboardImageMonitor &operator=(const ClipboardImageMonitor &) = delete;
  ClipboardImageMonitor(ClipboardImageMonitor &&) = delete;
  ClipboardImageMonitor &operator=(ClipboardImageMonitor &&) = delete;

  [[nodiscard]] ClipboardImageSource snapshot();

private:
  struct Native;
  ApplicationAllocator &memory_;
  Owned<Native, ApplicationAllocator> native_;
};

}
