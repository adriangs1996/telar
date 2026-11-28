#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;

namespace telar::gui::platform {

  class XcbClipboardImageMonitor {
  public:
    explicit XcbClipboardImageMonitor(ApplicationAllocator& memory);
    ~XcbClipboardImageMonitor();
    XcbClipboardImageMonitor(const XcbClipboardImageMonitor&) = delete;
    XcbClipboardImageMonitor& operator=(const XcbClipboardImageMonitor&) = delete;
    XcbClipboardImageMonitor(XcbClipboardImageMonitor&&) = delete;
    XcbClipboardImageMonitor& operator=(XcbClipboardImageMonitor&&) = delete;

    void cancel() noexcept;

    [[nodiscard]] ClipboardImageSource capture();

  private:
    struct Native;
    ApplicationAllocator& memory_;
    ds::Box<Native, ApplicationAllocator> native_;
  };

}
