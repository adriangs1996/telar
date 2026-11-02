#pragma once

#include "application/pane_layout.hpp"
#include "application/workbench_geometry.hpp"
#include "core/geometry.hpp"
#include <algorithm>
#include <array>
#include <cstddef>

namespace telar::gui {

struct PaneDecorationGeometry {
  static constexpr float frame_radius = 6;
  static constexpr float frame_line_width = 1;
  static constexpr float dim_alpha = 0.15F;
  static constexpr std::size_t panel_count = 6;

  Rect outer;
  Rect content;
  Rect frame;
  std::array<Rect, panel_count> panels;

  [[nodiscard]] static PaneDecorationGeometry derive(const PaneLayout::Placement &placement, const WorkbenchGeometry &workbench) noexcept {
    const auto outer = workbench.pixels(placement.bounds);
    const auto content = workbench.pixels(placement.content);
    auto frame = outer;
    const auto &grid = workbench.grid;
    const auto gap = workbench.layout_metrics.gap;
    const auto minimum_cell = std::min(grid.cell_width_px, grid.cell_height_px);
    const auto area = workbench.cellArea();
    if (placement.bounds.right() < area.right()) {
      frame.width += static_cast<float>(gap * (grid.cell_width_px - minimum_cell) / grid.scale);
    }

    if (placement.bounds.bottom() < area.bottom()) {
      frame.height += static_cast<float>(gap * (grid.cell_height_px - minimum_cell) / grid.scale);
    }

    const auto right = content.right();
    const auto bottom = content.bottom();
    return {
        .outer = outer,
        .content = content,
        .frame = frame,
        .panels = {
            Rect{.x = outer.x, .y = outer.y, .width = outer.width, .height = std::max(0.0F, content.y - outer.y)},
            Rect{.x = outer.x, .y = bottom, .width = outer.width, .height = std::max(0.0F, outer.bottom() - bottom)},
            Rect{.x = outer.x, .y = content.y, .width = std::max(0.0F, content.x - outer.x), .height = content.height},
            Rect{.x = right, .y = content.y, .width = std::max(0.0F, outer.right() - right), .height = content.height},
            Rect{.x = outer.right(), .y = outer.y, .width = frame.width - outer.width, .height = outer.height},
            Rect{.x = outer.x, .y = outer.bottom(), .width = outer.width, .height = frame.height - outer.height},
        },
    };
  }
};

}
