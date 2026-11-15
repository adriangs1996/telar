export module telar.gui.presentation.history_inspection_geometry;

import std;

import telar.gui.core.metrics;

import telar.gui.presentation.history_inspection;

import telar.gui.layout.geometry;
import telar.gui.presentation.history_filter_geometry;

// Interface: presentation/chrome_style.cppm
export {
  namespace telar::gui {

    // Logical radii and theme-relative state opacities shared by window chrome.
    struct ChromeStyle {
      static constexpr float small_radius = 4;
      static constexpr float control_radius = 6;
      static constexpr float surface_radius = 10;
      static constexpr float dialog_radius = 12;
      static constexpr float hover_alpha = 0.045F;
      static constexpr float selection_alpha = 0.09F;
      static constexpr float outline_alpha = 0.12F;
      static constexpr float focus_alpha = 0.65F;
    };

  }
}

// Interface: presentation/agent_card_geometry.cppm
export {
  namespace telar::gui {

    struct AgentCardGeometry {
      static constexpr float horizontal_padding = 8;
      static constexpr float vertical_padding = 8;
      static constexpr float compact_vertical_padding = 4;
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
      static constexpr float project_label_minimum = 24;
      static constexpr float title_gap = 4;
      static constexpr float total_row_spacing = 6;
      static constexpr float group_gap = 8;
      static constexpr float scrollbar_width = 3;
      static constexpr float icon_size_ratio = 0.85F;
      static constexpr float provider_alpha = 0.6F;

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
      [[nodiscard]] float compactHeight() const noexcept;
      [[nodiscard]] float cardWidth(float list_width) const noexcept;
      // The list width whose cards are `card_width` wide.
      [[nodiscard]] float listWidth(float card_width) const noexcept;
      [[nodiscard]] Rect row(Rect bounds, Row role) const noexcept;
    };

  }
}

// Interface: presentation/form_button_style.cppm
export {
  namespace telar::gui {

    struct FormButtonStyle {
      static constexpr float radius = ChromeStyle::control_radius;
      static constexpr float disabled_alpha = 0.4F;
      static constexpr float pressed_alpha = 0.8F;
    };

  }
}

// Interface: presentation/history_modal_geometry.cppm
export {
  namespace telar::gui {

    struct HistoryModalMetrics {
      Rect viewport{};
      ChromeMetrics chrome{};
      float cell_height = 0;
    };

    struct HistoryModalGeometry {
      static constexpr float maximum_width = 1360;
      static constexpr float minimum_height = 640;
      static constexpr float height_share = 0.8F;
      static constexpr float split_width = 900;
      static constexpr float list_share = 0.44F;
      static constexpr float margin = 28;
      static constexpr float margin_divisor = 12;
      static constexpr float row_minimum = 34;
      static constexpr float row_padding = 12;
      static constexpr float group_minimum = 28;
      static constexpr float group_padding = 10;
      static constexpr float header_minimum = 46;
      static constexpr float header_padding = 22;
      static constexpr float search_minimum = 52;
      static constexpr float search_padding = 24;
      static constexpr float footer_minimum = 36;
      static constexpr float footer_padding = 14;
      static constexpr float compact_width = 420;
      static constexpr float compact_height = 260;
      static constexpr float inspection_inset = 18;
      static constexpr float inspection_inset_divisor = 8;
      static constexpr float action_minimum = 28;
      static constexpr float action_padding = 8;

      Rect viewport;
      Rect bounds;
      Rect header;
      Rect results;
      Rect inspection;
      Rect search;
      Rect footer;
      float row_height = 0;
      float group_height = 0;
      bool compact = false;

      [[nodiscard]] static HistoryModalGeometry measure(const HistoryModalMetrics& metrics, bool inspecting) noexcept;
      void offsetY(float offset) noexcept;
      [[nodiscard]] Rect inspectionContent(const ChromeMetrics& chrome) const noexcept;
      [[nodiscard]] Rect inspectionActions(const ChromeMetrics& chrome) const noexcept;

    private:
      [[nodiscard]] float inspectionInset(const ChromeMetrics& chrome) const noexcept;
      static Rect takeBottom(Rect& remaining, float height) noexcept;
      static Rect takeTop(Rect& remaining, float height) noexcept;
    };

  }
}

// Interface: presentation/history_inspection_geometry.cppm
export {
  namespace telar::gui {

    struct HistoryInspectionGeometry {
      static constexpr std::size_t maximum_actions = history_inspection_action_count;
      static constexpr float command_padding = 8;
      static constexpr float fact_label_width = 64;
      static constexpr float fact_label_divisor = 3;
      static constexpr float button_padding = 24;
      static constexpr float button_gap = 8;
      static constexpr float button_radius = FormButtonStyle::radius;
      static constexpr float disabled_alpha = FormButtonStyle::disabled_alpha;
      static constexpr float pressed_alpha = FormButtonStyle::pressed_alpha;

      Rect content;
      Rect actions;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      float row_height = 0;
      float label_width = 0;
      float command_inset = 0;

      [[nodiscard]] static HistoryInspectionGeometry derive(Rect area, ChromeMetrics chrome, Point cell) noexcept;
      [[nodiscard]] Rect row(std::size_t index) const noexcept;
      [[nodiscard]] Rect text(Rect row, HistoryInspectionLine::Kind kind) const noexcept;
      [[nodiscard]] std::array<Rect, maximum_actions> buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept;
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
