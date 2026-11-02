#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace telar::gui {

struct Point {
  float x = 0;
  float y = 0;

  bool operator==(const Point &) const = default;
};

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;

  [[nodiscard]] float right() const noexcept {
    return x + width;
  }

  [[nodiscard]] float bottom() const noexcept {
    return y + height;
  }

  [[nodiscard]] bool contains(Point point) const noexcept {
    return point.x >= x && point.y >= y && point.x < right() && point.y < bottom();
  }

  [[nodiscard]] Rect intersect(Rect other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);

    return {.x = left, .y = top, .width = std::max(0.0F, std::min(right(), other.right()) - left), .height = std::max(0.0F, std::min(bottom(), other.bottom()) - top)};
  }

  [[nodiscard]] Rect inset(float horizontal, float vertical) const noexcept {
    return {.x = x + horizontal, .y = y + vertical, .width = std::max(0.0F, width - horizontal * 2), .height = std::max(0.0F, height - vertical * 2)};
  }

  [[nodiscard]] bool empty() const noexcept {
    return width <= 0 || height <= 0;
  }

  bool operator==(const Rect &) const = default;
};

struct Viewport {
  static constexpr float maximum_scale = 8;

  std::uint32_t width = 0;
  std::uint32_t height = 0;
  float scale = 1;
  std::uint32_t controls = 0;

  [[nodiscard]] bool valid() const noexcept {
    return width != 0 && height != 0 && std::isfinite(scale) && scale > 0 && scale <= maximum_scale;
  }

  bool operator==(const Viewport &) const = default;
};

}
