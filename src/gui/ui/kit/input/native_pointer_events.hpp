#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/ds/containers.hpp"

#pragma once

import telar.gui.foundation.core;


namespace telar::gui::qt {

  class NativePointerEvents {
  public:
    explicit NativePointerEvents(ApplicationAllocator& memory);
    ~NativePointerEvents();
    NativePointerEvents(const NativePointerEvents&) = delete;
    NativePointerEvents& operator=(const NativePointerEvents&) = delete;
    NativePointerEvents(NativePointerEvents&&) = delete;
    NativePointerEvents& operator=(NativePointerEvents&&) = delete;

    [[nodiscard]] bool moving() const noexcept;

  private:
    struct Native;
    ds::Box<Native, ApplicationAllocator> native_;
  };

}
