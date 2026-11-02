#pragma once

#include "core/cell_rectangle.hpp"
#include "terminal/cell_position.hpp"
#include <algorithm>
#include <cstdint>
#include <optional>

namespace telar::gui {

struct PathPickerPlacement {
  static constexpr std::uint16_t maximum_rows = 10;
  static constexpr std::uint16_t maximum_width = 72;
  static constexpr std::uint16_t chrome_rows = 4;
  static constexpr std::uint16_t cursor_inset = 2;
  static constexpr std::uint16_t fallback_vertical_divisor = 3;

  CellRectangle area;
  bool flipped = false;

  [[nodiscard]] static PathPickerPlacement forPage(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t count) noexcept {
    const auto rows = std::max<std::uint16_t>(1, std::min(count, maximum_rows));

    return place(host, cursor, maximum_width, static_cast<std::uint16_t>(rows + chrome_rows));
  }

  [[nodiscard]] static PathPickerPlacement place(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t requested_width, std::uint16_t requested_height) noexcept {
    const auto width = std::min(requested_width, host.width);
    const auto height = std::min(requested_height, host.height);
    if (!cursor) {
      return {.area = {.x = static_cast<std::uint16_t>(host.x + ((host.width - width) / 2)), .y = static_cast<std::uint16_t>(host.y + ((host.height - height) / fallback_vertical_divisor)), .width = width, .height = height}};
    }

    const auto left = cursor->x > cursor_inset ? cursor->x - cursor_inset : 0;
    const auto x = std::min<unsigned>(left, host.x + host.width - width);
    const auto host_bottom = static_cast<unsigned>(host.y) + host.height;
    const auto next_row = static_cast<unsigned>(cursor->y) + 1;
    const auto below = host_bottom > next_row ? host_bottom - next_row : 0;
    const auto above = cursor->y > host.y ? cursor->y - host.y : 0;
    const auto flipped = below < height && above > below;
    const auto room = flipped ? above : below;
    const auto fitted = static_cast<std::uint16_t>(std::min<unsigned>(height, room));

    return {
        .area = {.x = static_cast<std::uint16_t>(std::max<unsigned>(x, host.x)), .y = static_cast<std::uint16_t>(flipped ? cursor->y - fitted : next_row), .width = width, .height = fitted},
        .flipped = flipped,
    };
  }
};

}
