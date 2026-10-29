#pragma once

#include "core/cell_rectangle.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct NamePromptGeometry {
  static constexpr std::uint16_t requested_width = 64;
  static constexpr std::uint16_t requested_height = 7;
  static constexpr std::uint16_t horizontal_threshold = 12;
  static constexpr std::uint16_t vertical_threshold = 6;
  static constexpr std::uint16_t horizontal_margin = 2;
  static constexpr std::uint16_t vertical_margin = 1;

  CellRectangle bounds;
  CellRectangle title;
  CellRectangle field;
  CellRectangle footer;

  [[nodiscard]] static NamePromptGeometry measure(CellRectangle host) noexcept {
    const auto margin_x = host.width > horizontal_threshold ? horizontal_margin : 0;
    const auto margin_y = host.height > vertical_threshold ? vertical_margin : 0;
    const auto width = std::min(requested_width, static_cast<std::uint16_t>(host.width - (margin_x * 2)));
    const auto height = std::min(requested_height, static_cast<std::uint16_t>(host.height - (margin_y * 2)));
    NamePromptGeometry result;
    result.bounds = {.x = coordinate(static_cast<std::uint32_t>(host.x) + ((host.width - width) / 2)), .y = coordinate(static_cast<std::uint32_t>(host.y) + ((host.height - height) / 2)), .width = width, .height = height};
    const auto content = width > 2 && height > 2 ? result.bounds.inner(1) : result.bounds;
    if (width > 4) {
      result.title = {.x = coordinate(static_cast<std::uint32_t>(result.bounds.x) + 2), .y = result.bounds.y, .width = static_cast<std::uint16_t>(width - 4), .height = 1};
    }

    result.field = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + (content.height > 2 ? 1 : 0)), .width = content.width, .height = std::min<std::uint16_t>(1, content.height)};
    if (content.height > 2) {
      result.footer = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + content.height - 1), .width = content.width, .height = 1};
    }

    return result;
  }

private:
  [[nodiscard]] static std::uint16_t coordinate(std::uint32_t value) noexcept {
    return static_cast<std::uint16_t>(std::min<std::uint32_t>(value, std::numeric_limits<std::uint16_t>::max()));
  }
};

}
