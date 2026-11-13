#pragma once

#include <string_view>

class QWindow;

namespace telar::gui::platform {

#ifdef __APPLE__
inline constexpr bool native_composition_events = true;

[[nodiscard]] bool isCompositionCancellation(std::string_view event_type, const void *message, const QWindow &window) noexcept;
#else
inline constexpr bool native_composition_events = false;

[[nodiscard]] inline bool isCompositionCancellation([[maybe_unused]] std::string_view event_type, [[maybe_unused]] const void *message, [[maybe_unused]] const QWindow &window) noexcept {
  return false;
}
#endif

}
