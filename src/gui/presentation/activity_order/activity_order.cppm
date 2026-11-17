export module telar.gui.presentation.activity_order;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

// Interface: presentation/pane_chrome.cppm
export {
  namespace telar::gui {

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
