#pragma once

#include "input/wheel_accumulator.hpp"
#include <optional>
#include <string_view>

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
[[nodiscard]] std::optional<NativeScrollInput> nativeScrollInput(std::string_view event_type, const void *message, const QWindow &window) noexcept;
#else
inline constexpr bool native_scroll_events = false;

[[nodiscard]] inline std::optional<NativeScrollInput> nativeScrollInput([[maybe_unused]] std::string_view event_type, [[maybe_unused]] const void *message, [[maybe_unused]] const QWindow &window) noexcept {
  return {};
}
#endif

}
