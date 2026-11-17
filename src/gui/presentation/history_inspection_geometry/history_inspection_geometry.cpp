module telar.gui.presentation.history_inspection_geometry;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;

namespace telar::gui {

  PaneDecorationGeometry PaneDecorationGeometry::derive(const PaneLayout::Placement& placement, const WorkbenchGeometry& workbench) noexcept {
    const auto outer = workbench.pixels(placement.bounds);
    const auto content = workbench.pixels(placement.content);
    auto frame = outer;
    const auto& grid = workbench.grid;
    const auto gap = workbench.layout_metrics.gap;
    const auto minimum_cell = std::min(grid.cell_width_px, grid.cell_height_px);
    const auto area = workbench.cellArea();
    if (placement.bounds.right() < area.right()) {
      frame.width += static_cast<float>(gap * (grid.cell_width_px - minimum_cell) / grid.scale);
    }

    if (placement.bounds.bottom() < area.bottom()) {
      frame.height += static_cast<float>(gap * (grid.cell_height_px - minimum_cell) / grid.scale);
    }

    // Frames on the workbench edge absorb the columns' rounding, so outer margins stay even.
    if (placement.framed && gap != 0) {
      if (placement.bounds.right() >= area.right()) {
        frame.width = std::max(frame.width, workbench.area.right() - frame.x);
      }

      if (placement.bounds.bottom() >= area.bottom()) {
        frame.height = std::max(frame.height, workbench.area.bottom() - frame.y);
      }
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

  PaneAttentionGeometry PaneAttentionGeometry::derive(Rect physical_frame, float physical_ratio, float logical_radius) noexcept {
    return {
        .bounds = physical_frame.inset(inset_pixels, inset_pixels),
        .width = line_width * physical_ratio,
        .radius = std::max(0.0F, (logical_radius * physical_ratio) - inset_pixels),
    };
  }

}
