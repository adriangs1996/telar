#pragma once

#include "core/cell_rectangle.hpp"
#include "name_prompt_geometry.hpp"
#include <cstdint>

namespace telar::gui {

struct PeekGeometry {
  static constexpr CellRectangle requested_size{.width = 96, .height = 24};
  static constexpr std::uint16_t chrome_rows = 4;
  static constexpr std::uint16_t field_rows_from_end = 2;

  CellRectangle bounds;
  CellRectangle title;
  CellRectangle facts;
  CellRectangle screen;
  CellRectangle field;
  CellRectangle footer;

  [[nodiscard]] static PeekGeometry measure(CellRectangle host) noexcept {
    const auto modal = NamePromptGeometry::measure(host, requested_size);
    PeekGeometry result;
    result.bounds = modal.bounds;
    result.title = modal.title;
    const auto content = result.bounds.width > 2 && result.bounds.height > 2 ? result.bounds.inner(1) : result.bounds;
    if (content.height < chrome_rows) {
      return result;
    }

    result.facts = content.row(0);
    result.screen = content.row(1);
    result.screen.height = content.height - chrome_rows;
    result.field = content.row(content.height - field_rows_from_end);
    result.footer = content.row(content.height - 1);

    return result;
  }
};

}
