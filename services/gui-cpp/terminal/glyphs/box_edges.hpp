#pragma once

#include <cstdint>
#include <initializer_list>

namespace telar::gui::glyphs {

enum class BoxWeight : std::uint8_t {
  none,
  light,
  heavy,
  double_line,
};

struct BoxEdges {
  BoxWeight up = BoxWeight::none;
  BoxWeight right = BoxWeight::none;
  BoxWeight down = BoxWeight::none;
  BoxWeight left = BoxWeight::none;

  [[nodiscard]] bool empty() const noexcept {
    return up == BoxWeight::none && right == BoxWeight::none && down == BoxWeight::none && left == BoxWeight::none;
  }

  void simplifyDoubles() noexcept {
    for (auto *edge : {&up, &right, &down, &left}) {
      if (*edge == BoxWeight::double_line) {
        *edge = BoxWeight::light;
      }
    }
  }
};

}
