#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace telar::gui::glyphs {

struct BoxStroke {
  std::uint16_t units_per_em = 0;
  std::int16_t underline_thickness = 0;

  [[nodiscard]] float pixels(std::uint16_t pixel_height) const noexcept {
    constexpr float fallback_divisor = 16;
    const auto height = static_cast<float>(pixel_height);
    const auto thickness = units_per_em == 0 || underline_thickness <= 0 ? height / fallback_divisor : static_cast<float>(underline_thickness) * height / static_cast<float>(units_per_em);

    return std::max(1.0F, std::ceil(thickness));
  }
};

}
