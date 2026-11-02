#pragma once

#include "core/geometry.hpp"
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <stdexcept>

namespace telar::gui::glyphs {

inline void validateCell(Rect cell) {
  constexpr auto maximum_extent = std::numeric_limits<std::uint16_t>::max();
  const auto finite_origin = std::isfinite(cell.x) && std::isfinite(cell.y);
  const auto finite_extent = std::isfinite(cell.width) && std::isfinite(cell.height);
  if (!finite_origin || !finite_extent || cell.width < 0 || cell.height < 0 || cell.width > maximum_extent || cell.height > maximum_extent) {
    throw std::invalid_argument{"InvalidCellBounds"};
  }
}

template <std::size_t Capacity>
class Ink {
public:
  explicit Ink(float coverage = 1) noexcept
      : coverage_(coverage) {}

  [[nodiscard]] float coverage() const noexcept {
    return coverage_;
  }

  [[nodiscard]] std::span<const Rect> rectangles() const noexcept {
    return std::span{rectangles_}.first(count_);
  }

  void push(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    if (count_ == Capacity) {
      throw std::length_error{"GlyphRectangleBudgetExceeded"};
    }

    rectangles_[count_++] = rectangle;
  }

  void appendMerged(Rect rectangle) {
    if (rectangle.empty()) {
      return;
    }

    for (auto &previous : std::span{rectangles_}.first(count_)) {
      if (previous.x == rectangle.x && previous.width == rectangle.width && previous.bottom() == rectangle.y) {
        previous.height += rectangle.height;

        return;
      }
    }

    push(rectangle);
  }

  void translate(Point origin) noexcept {
    for (auto &rectangle : std::span{rectangles_}.first(count_)) {
      rectangle.x += origin.x;
      rectangle.y += origin.y;
    }
  }

private:
  std::array<Rect, Capacity> rectangles_{};
  std::size_t count_ = 0;
  float coverage_;
};

}
