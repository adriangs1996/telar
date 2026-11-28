#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/scroll_event.hpp"
#include "platform/macos/scroll_event_bridge.h"
#include <QWindow>
#include <bit>
#include <string_view>

import telar.base.ds;
import telar.gui.foundation.core;

namespace telar::gui::platform {
  namespace {

    ScrollPhase decodePhase(std::uint8_t phase) noexcept {
      switch (phase) {
      case 1:
        return ScrollPhase::begin;
      case 2:
        return ScrollPhase::update;
      case 3:
        return ScrollPhase::end;
      case 4:
        return ScrollPhase::cancel;
      default:
        return ScrollPhase::none;
      }
    }

  }

  ds::Option<NativeScrollInput> nativeScrollInput(std::string_view event_type, const void* message, const QWindow& window) noexcept {
    if ((event_type != "mac_generic_NSEvent" && event_type != "NSEvent") || message == nullptr || window.handle() == nullptr) {
      return {};
    }

    TelarGuiNativeScrollInput raw{};
    if (!telarGuiReadNativeScrollInput(message, std::bit_cast<const void*>(window.winId()), &raw)) {
      return {};
    }

    return NativeScrollInput{
        .sample = {.delta = raw.delta, .precise = raw.precise, .phase = decodePhase(raw.phase)},
        .x = raw.x,
        .y = raw.y,
        .valid = raw.valid,
    };
  }

}
