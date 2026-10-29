#pragma once

#include "core/geometry.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace telar::gui::fonts {

struct IconPlacement {
  Point origin;
  Point ink_origin;
  float scale = 0;

  [[nodiscard]] static IconPlacement resolve(Rect ink, Rect bounds, float requested_side) {
    if (!std::isfinite(requested_side) || !std::isfinite(bounds.x) || !std::isfinite(bounds.y) || !std::isfinite(bounds.width) || !std::isfinite(bounds.height)) {
      throw std::invalid_argument{"InvalidIconBounds"};
    }

    const auto side = std::min({requested_side, bounds.width, bounds.height});
    if (ink.empty() || side <= 0) {
      return {};
    }

    const auto left = bounds.x + ((bounds.width - side) / 2);
    const auto top = bounds.y + ((bounds.height - side) / 2);
    const auto scale = std::min(side / ink.width, side / ink.height);

    return {.origin = {.x = left + ((side - (ink.width * scale)) / 2), .y = top + ((side - (ink.height * scale)) / 2)}, .ink_origin = {.x = ink.x, .y = ink.y}, .scale = scale};
  }

  [[nodiscard]] Rect map(Rect glyph) const noexcept {
    return {.x = origin.x + ((glyph.x - ink_origin.x) * scale), .y = origin.y + ((glyph.y - ink_origin.y) * scale), .width = glyph.width * scale, .height = glyph.height * scale};
  }
};

}
