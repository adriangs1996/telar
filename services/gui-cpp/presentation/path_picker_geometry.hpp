#pragma once

#include "core/cell_rectangle.hpp"
#include "path_picker_placement.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

struct PathPickerFieldColumns {
  std::uint16_t root = 0;
  std::uint16_t count = 0;
};

struct PathPickerRowPlacement {
  CellRectangle bounds;
  std::size_t index = 0;
};

struct PathPickerGeometry {
  CellRectangle root_label;
  CellRectangle query;
  CellRectangle count_label;
  CellRectangle footer;
  CellRectangle empty;
  std::array<PathPickerRowPlacement, PathPickerPlacement::maximum_rows> rows{};
  std::size_t row_count = 0;

  [[nodiscard]] static PathPickerGeometry measure(PathPickerPlacement placement, std::size_t total, std::size_t selection, PathPickerFieldColumns columns) noexcept {
    PathPickerGeometry result;
    const auto content = placement.area.inner(1);
    constexpr std::uint16_t field_and_footer_rows = 2;
    if (content.height <= field_and_footer_rows) {
      return result;
    }

    auto field = content;
    field.y = placement.flipped ? static_cast<std::uint16_t>(content.y + content.height - 1) : content.y;
    field.height = 1;
    result.footer = field;
    result.footer.y = placement.flipped ? content.y : static_cast<std::uint16_t>(content.y + content.height - 1);
    const auto count_columns = std::min<std::uint16_t>(columns.count, field.width / 4);
    const auto count_room = std::min<std::uint16_t>(field.width, static_cast<std::uint16_t>(count_columns + 1));
    const auto field_columns = static_cast<std::uint16_t>(field.width - count_room);
    const auto count_inset = std::min<std::uint16_t>(1, count_room);
    result.count_label = {.x = static_cast<std::uint16_t>(field.x + field_columns + count_inset), .y = field.y, .width = static_cast<std::uint16_t>(count_room - count_inset), .height = 1};
    const auto root_columns = std::min<std::uint16_t>(static_cast<std::uint16_t>(columns.root + 1), field_columns / 2);
    result.root_label = {.x = field.x, .y = field.y, .width = root_columns, .height = 1};
    result.query = {.x = static_cast<std::uint16_t>(field.x + root_columns), .y = field.y, .width = static_cast<std::uint16_t>(field_columns - root_columns), .height = 1};

    const auto row_area = CellRectangle{.x = content.x, .y = static_cast<std::uint16_t>(content.y + 1), .width = content.width, .height = static_cast<std::uint16_t>(content.height - field_and_footer_rows)};
    const auto count = std::min<std::size_t>({row_area.height, total, result.rows.size()});
    const auto selected = total == 0 ? 0 : std::min(selection, total - 1);
    const auto first = selected + 1 > count ? selected + 1 - count : 0;
    result.empty = {.x = static_cast<std::uint16_t>(row_area.x + std::min<std::uint16_t>(2, row_area.width)), .y = placement.flipped ? static_cast<std::uint16_t>(row_area.y + row_area.height - 1) : row_area.y, .width = static_cast<std::uint16_t>(row_area.width - std::min<std::uint16_t>(2, row_area.width)), .height = 1};
    for (std::size_t offset = 0; offset < count; ++offset) {
      const auto row = placement.flipped ? row_area.height - 1 - offset : offset;
      result.rows[offset] = {.bounds = {.x = row_area.x, .y = static_cast<std::uint16_t>(row_area.y + row), .width = row_area.width, .height = 1}, .index = first + offset};
    }

    result.row_count = count;

    return result;
  }
};

}
