#pragma once

#include <string_view>

class QWindow;

namespace telar::gui::platform {

#ifdef __APPLE__
  inline constexpr bool native_composition_events = true;

  [[nodiscard]] bool isCompositionCancellation(std::string_view event_type, const void* message, const QWindow& window) noexcept;

  // Whether the keyboard layout in use is one whose users take Option for Alt, as Ghostty
  // decides it: U.S., ABC (U.S. by another name) and U.S. International, where Option types
  // symbols a terminal rarely wants (Option+B is ∫). Other layouts type with Option characters
  // no other key gives, as Option+2 is `@` on a Spanish one.
  [[nodiscard]] bool layoutTakesOptionForAlt() noexcept;
#else
  inline constexpr bool native_composition_events = false;

  [[nodiscard]] inline bool isCompositionCancellation([[maybe_unused]] std::string_view event_type, [[maybe_unused]] const void* message, [[maybe_unused]] const QWindow& window) noexcept {
    return false;
  }

  [[nodiscard]] inline bool layoutTakesOptionForAlt() noexcept {
    return false;
  }
#endif

}
