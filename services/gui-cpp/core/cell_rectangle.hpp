#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct CellRectangle {
  std::uint16_t x = 0;
  std::uint16_t y = 0;
  std::uint16_t width = 0;
  std::uint16_t height = 0;

  [[nodiscard]] std::uint32_t right() const noexcept {
    return static_cast<std::uint32_t>(x) + width;
  }

  [[nodiscard]] std::uint32_t bottom() const noexcept {
    return static_cast<std::uint32_t>(y) + height;
  }

  [[nodiscard]] bool empty() const noexcept {
    return width == 0 || height == 0;
  }

  [[nodiscard]] CellRectangle inner(std::uint16_t margin) const noexcept {
    const auto shrink = static_cast<std::uint32_t>(margin) * 2;
    if (width <= shrink || height <= shrink) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();
    return {
        .x = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(x) + margin, static_cast<std::uint32_t>(maximum))),
        .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + margin, static_cast<std::uint32_t>(maximum))),
        .width = static_cast<std::uint16_t>(width - shrink),
        .height = static_cast<std::uint16_t>(height - shrink),
    };
  }

  [[nodiscard]] CellRectangle intersect(CellRectangle other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);
    const auto end = std::max<std::uint32_t>(left, std::min(right(), other.right()));
    const auto lower = std::max<std::uint32_t>(top, std::min(bottom(), other.bottom()));

    return {.x = left, .y = top, .width = static_cast<std::uint16_t>(end - left), .height = static_cast<std::uint16_t>(lower - top)};
  }

  bool operator==(const CellRectangle &) const = default;
};

}
