#pragma once

#include "core/geometry.hpp"
#include <algorithm>
#include <limits>

namespace telar::gui::fonts {

struct InkBounds {
  float left = std::numeric_limits<float>::infinity();
  float top = std::numeric_limits<float>::infinity();
  float right = -std::numeric_limits<float>::infinity();
  float bottom = -std::numeric_limits<float>::infinity();

  void include(Rect area) noexcept {
    left = std::min(left, area.x);
    top = std::min(top, area.y);
    right = std::max(right, area.right());
    bottom = std::max(bottom, area.bottom());
  }

  [[nodiscard]] Rect rect() const noexcept {
    return right > left && bottom > top ? Rect{.x = left, .y = top, .width = right - left, .height = bottom - top} : Rect{};
  }
};

}
