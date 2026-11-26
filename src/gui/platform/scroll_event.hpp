#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <string_view>

#pragma once

import telar.base.ds;
import telar.gui.foundation.core;

class QWindow;

namespace telar::gui::platform {

  struct NativeScrollInput {
    ScrollSample sample;
    double x = 0;
    double y = 0;
    bool valid = false;
  };

#ifdef __APPLE__
  inline constexpr bool native_scroll_events = true;
  [[nodiscard]] ds::Option<NativeScrollInput> nativeScrollInput(std::string_view event_type, const void* message, const QWindow& window) noexcept;
#else
  inline constexpr bool native_scroll_events = false;

  [[nodiscard]] inline ds::Option<NativeScrollInput> nativeScrollInput([[maybe_unused]] std::string_view event_type, [[maybe_unused]] const void* message, [[maybe_unused]] const QWindow& window) noexcept {
    return {};
  }
#endif

}
