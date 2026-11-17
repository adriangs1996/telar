export module telar.gui.presentation.history_inspection_geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.model;

// Interface: presentation/pane_decoration_geometry.cppm
export {
  namespace telar::gui {

    struct PaneDecorationGeometry {
      static constexpr float frame_radius = ChromeStyle::dialog_radius;
      static constexpr float frame_line_width = 1;
      static constexpr float dim_alpha = 0.28F;
      static constexpr std::size_t panel_count = 6;

      Rect outer;
      Rect content;
      Rect frame;
      std::array<Rect, panel_count> panels;

      [[nodiscard]] static PaneDecorationGeometry derive(const PaneLayout::Placement& placement, const WorkbenchGeometry& workbench) noexcept;
    };

  }
}

// Interface: presentation/pane_attention_geometry.cppm
export {
  namespace telar::gui {

    struct PaneAttentionGeometry {
      static constexpr float line_width = 2;
      static constexpr float inset_pixels = 1;

      Rect bounds;
      float width = 0;
      float radius = 0;

      [[nodiscard]] static PaneAttentionGeometry derive(Rect physical_frame, float physical_ratio, float logical_radius = PaneDecorationGeometry::frame_radius) noexcept;
    };

  }
}
