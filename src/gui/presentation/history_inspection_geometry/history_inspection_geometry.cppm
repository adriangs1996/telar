export module telar.gui.presentation.history_inspection_geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.model;

// Interface: presentation/agent_card_geometry.cppm
export {
  namespace telar::gui {

    struct AgentCardGeometry {
      static constexpr float horizontal_padding = 8;
      static constexpr float vertical_padding = 8;
      static constexpr float task_indent = 12;
      static constexpr float spacing = 3;
      static constexpr float radius = ChromeStyle::surface_radius;
      static constexpr float gap = 6;
      static constexpr float mark_side = 14;
      static constexpr float tile_width = 18;
      static constexpr float tile_height = 14;
      // Every card keeps its mark in this column, so titles and details share one left edge.
      static constexpr float mark_column = 24;
      static constexpr float project_label_gap = 4;
      static constexpr float title_gap = 4;
      static constexpr float total_row_spacing = 6;
      static constexpr float group_gap = 8;
      static constexpr float scrollbar_width = 3;
      static constexpr float icon_size_ratio = 0.85F;
      static constexpr float provider_alpha = 0.6F;
      // The badge that carries an agent's state on the lower right corner of its tile.
      static constexpr float badge_side = 11;
      // The plan's progress line under an agent card's rows.
      static constexpr float plan_bar_height = 2;
      // The tint and ring of a card whose agent waits on the person.
      static constexpr float attention_alpha = 0.075F;
      static constexpr float attention_outline_alpha = 0.22F;

      enum class Row : std::uint8_t {
        context,
        title,
        detail,
      };

      float small_row = 0;
      float title_row = 0;
      float scale = 1;

      [[nodiscard]] static AgentCardGeometry derive(const ChromeMetrics& chrome) noexcept;
      [[nodiscard]] float px(float logical) const noexcept;
      // Where a card's text starts: past its inset, its mark column and the gap after it.
      [[nodiscard]] float textInset() const noexcept;
      [[nodiscard]] float height() const noexcept;
      [[nodiscard]] float agentHeight() const noexcept;
      [[nodiscard]] float cardWidth(float list_width) const noexcept;
      // The list width whose cards are `card_width` wide.
      [[nodiscard]] float listWidth(float card_width) const noexcept;
      [[nodiscard]] Rect row(Rect bounds, Row role) const noexcept;
    };

  }
}

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
