#pragma once

#include "core/geometry.hpp"
#include <algorithm>
#include <cmath>

namespace telar::gui::fonts {

struct GlyphTransform {
  float x = 0;
  float y = 0;
  float scale = 1;

  [[nodiscard]] static GlyphTransform fit(Rect ink, Rect cell) noexcept {
    if (!std::isfinite(ink.width) || ink.width <= 0 || ink.height <= 0) {
      return {};
    }

    const auto scale = std::min({1.0F, cell.width / ink.width, cell.height / ink.height});
    const auto top = ink.y * scale;
    const auto bottom = top + (ink.height * scale);

    float vertical_shift = 0;
    if (top < cell.y) {
      vertical_shift = cell.y - top;
    } else if (bottom > cell.bottom()) {
      vertical_shift = cell.bottom() - bottom;
    }

    return {
        .x = cell.x + ((cell.width - (ink.width * scale)) / 2) - (ink.x * scale),
        .y = vertical_shift,
        .scale = scale,
    };
  }

  [[nodiscard]] Rect map(Rect ink) const noexcept {
    return {.x = (ink.x * scale) + x, .y = (ink.y * scale) + y, .width = ink.width * scale, .height = ink.height * scale};
  }
};

}
