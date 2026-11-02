#pragma once

#include "source_rect.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct ImageDisplayBox {
  struct Cell {
    std::uint32_t width = 0;
    std::uint32_t height = 0;

    bool operator==(const Cell &) const noexcept = default;
  };

  std::int64_t x = 0;
  std::int64_t y = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  [[nodiscard]] static ImageDisplayBox resolve(const GraphicsPlacement &placement, ImageSourceRect source, Cell cell) noexcept {
    const auto offset_x = cell.width == 0 ? 0 : std::min(placement.offset_x, cell.width - 1);
    const auto offset_y = cell.height == 0 ? 0 : std::min(placement.offset_y, cell.height - 1);
    auto width = source.width;
    auto height = source.height;
    if (placement.columns != 0) {
      const auto filled = filledExtent(cell.width, placement.columns);
      width = filled - std::min(filled, offset_x);
    }

    if (placement.rows != 0) {
      const auto filled = filledExtent(cell.height, placement.rows);
      height = filled - std::min(filled, offset_y);
    }

    if (placement.columns != 0 && placement.rows == 0) {
      height = proportionalExtent(width, source.height, source.width);
    } else if (placement.columns == 0 && placement.rows != 0) {
      width = proportionalExtent(height, source.width, source.height);
    }

    return {.x = (static_cast<std::int64_t>(placement.x) * cell.width) + offset_x, .y = (static_cast<std::int64_t>(placement.y) * cell.height) + offset_y, .width = width, .height = height};
  }

private:
  [[nodiscard]] static std::uint32_t filledExtent(std::uint32_t cell, std::uint32_t count) noexcept {
    const auto extent = static_cast<std::uint64_t>(cell) * count;

    return static_cast<std::uint32_t>(std::min<std::uint64_t>(extent, std::numeric_limits<std::uint32_t>::max()));
  }

  [[nodiscard]] static std::uint32_t proportionalExtent(std::uint32_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept {
    if (denominator == 0) {
      return 0;
    }

    const auto rounded = ((static_cast<std::uint64_t>(value) * numerator) + (denominator / 2)) / denominator;

    return static_cast<std::uint32_t>(std::min<std::uint64_t>(rounded, std::numeric_limits<std::uint32_t>::max()));
  }
};

}
