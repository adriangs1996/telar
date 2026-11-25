// What a pane and a workspace wear: a pane's header, status chip and progress, the frame and
// panels that decorate it and the ring of its attention, and a workspace's mark.
export module telar.gui.features.workbench:chrome;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.model;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: presentation/pane_chrome.cppm
export {
  namespace telar::gui::features::workbench {

    struct PaneStatusChip {
      static constexpr float inset = 8;
      static constexpr float height = 20;
      static constexpr float radius = 6;
      static constexpr std::size_t text_capacity = 32;
      using Text = BoundedText<text_capacity>;

      [[nodiscard]] static Text text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds);

      [[nodiscard]] static PaletteRole color(AgentStatus status) noexcept;
    };

    struct PaneProgressPresentation {
      static constexpr std::size_t text_capacity = 24;
      using Text = BoundedText<text_capacity>;

      [[nodiscard]] static Text text(PaneProgressState state, std::uint8_t percent);

      [[nodiscard]] static PaletteRole color(PaneProgressState state) noexcept;
    };

    struct PaneHeaderMetrics {
      float ratio = 1;
      float maximum_band_height = 0;
    };

    struct PaneHeaderMeasurements {
      float index = 0;
      float name = 0;
      float chip = 0;
      float paused = 0;
      float progress = 0;
      float compact_progress = 0;
      bool needs_attention = false;
    };

    struct PaneHeaderGeometry {
      static constexpr float margin = 8;
      static constexpr float part_gap = 6;
      static constexpr float chip_gap = 8;
      static constexpr float minimum_text_room = 12;

      Rect index;
      Rect name;
      Rect paused;
      Rect chip;
      Rect progress;
      bool compact_progress = false;

      bool operator==(const PaneHeaderGeometry&) const = default;

      [[nodiscard]] static PaneHeaderGeometry derive(Rect row, const PaneHeaderMetrics& metrics, const PaneHeaderMeasurements& measurements) noexcept;
    };

  }
}

// Interface: presentation/workspace_mark.cppm
export {
  namespace telar::gui::features::workbench {

    struct WorkspaceMark {
      static constexpr auto hues = ds::Array<PaletteRole, 7>{PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve};

      Utf8Scalar initial;
      PaletteRole hue = hues.front();

      [[nodiscard]] static WorkspaceMark resolve(std::string_view name);
      // Gives the marks of one machine's workspaces, in the order they were made, hues no two
      // share until the palette runs out: each keeps the hue its name hashes to while no older
      // mark holds it, and otherwise takes the next free one.
      static void distinguish(std::span<WorkspaceMark> marks) noexcept;

    private:
      [[nodiscard]] static std::uint32_t hash(std::string_view name) noexcept;
    };

  }
}

// Interface: presentation/pane_decoration_geometry.cppm
export {
  namespace telar::gui::features::workbench {

    struct PaneDecorationGeometry {
      static constexpr float frame_radius = ChromeStyle::dialog_radius;
      static constexpr float frame_line_width = 1;
      static constexpr float dim_alpha = 0.28F;
      static constexpr std::size_t panel_count = 6;

      Rect outer;
      Rect content;
      Rect frame;
      ds::Array<Rect, panel_count> panels;

      [[nodiscard]] static PaneDecorationGeometry derive(const PaneLayout::Placement& placement, const WorkbenchGeometry& workbench) noexcept;
    };

  }
}

// Interface: presentation/pane_attention_geometry.cppm
export {
  namespace telar::gui::features::workbench {

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
