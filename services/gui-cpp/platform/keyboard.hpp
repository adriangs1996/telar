#pragma once

#include <cstdint>

namespace telar::gui::platform {

enum class KeyboardConvention : std::uint8_t {
  standard,
  apple,
};

#ifdef __APPLE__
inline constexpr auto keyboard_convention = KeyboardConvention::apple;
#else
inline constexpr auto keyboard_convention = KeyboardConvention::standard;
#endif

}
