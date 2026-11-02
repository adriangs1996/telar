#pragma once

#include "core/cell_rectangle.hpp"
#include "core/geometry.hpp"
#include "core/terminal_size.hpp"
#include "pane_layout.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui {

struct WorkbenchGeometry {
  static constexpr float default_width = default_terminal_size.cols * default_terminal_size.cell_width_px;
  static constexpr float default_height = default_terminal_size.rows * default_terminal_size.cell_height_px;

  Rect area{.width = default_width, .height = default_height};
  TerminalGrid grid;
  PaneLayout::Metrics layout_metrics;

  bool operator==(const WorkbenchGeometry &) const = default;

  [[nodiscard]] std::optional<TerminalSize> launchSize() const noexcept {
    return grid.fit(area.width, area.height);
  }

  [[nodiscard]] CellRectangle cellArea() const noexcept {
    const auto size = launchSize();

    return size ? CellRectangle{.width = size->cols, .height = size->rows} : CellRectangle{};
  }

  [[nodiscard]] std::optional<TerminalSize> contentSize(CellRectangle content) const noexcept {
    if (content.empty() || static_cast<std::size_t>(content.width) * content.height > TerminalGrid::maximum_cells) {
      return std::nullopt;
    }

    return TerminalSize{.cols = content.width, .rows = content.height, .cell_width_px = grid.cell_width_px, .cell_height_px = grid.cell_height_px};
  }

  [[nodiscard]] Rect pixels(CellRectangle cells) const noexcept {
    return {
        .x = area.x + static_cast<float>(static_cast<std::uint32_t>(cells.x) * grid.cell_width_px / grid.scale),
        .y = area.y + static_cast<float>(static_cast<std::uint32_t>(cells.y) * grid.cell_height_px / grid.scale),
        .width = static_cast<float>(static_cast<std::uint32_t>(cells.width) * grid.cell_width_px / grid.scale),
        .height = static_cast<float>(static_cast<std::uint32_t>(cells.height) * grid.cell_height_px / grid.scale),
    };
  }
};

}
