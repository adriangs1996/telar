#pragma once

#include "core/geometry.hpp"
#include "ink.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace telar::gui::glyphs {

struct BoxMetrics {
  float width = 0;
  float height = 0;
  float light = 0;
  float heavy = 0;

  [[nodiscard]] static BoxMetrics resolve(Rect cell, float thickness) {
    validateCell(cell);
    if (!std::isfinite(thickness) || thickness <= 0) {
      throw std::invalid_argument{"InvalidCellBounds"};
    }

    const auto minimum_extent = std::min(cell.width, cell.height);

    return {.width = cell.width, .height = cell.height, .light = std::min(minimum_extent, thickness), .heavy = std::min(minimum_extent, 2 * thickness)};
  }
};

}
