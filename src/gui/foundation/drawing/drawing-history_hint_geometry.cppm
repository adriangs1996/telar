export module telar.gui.foundation.drawing:history_hint_geometry;

import std;

import telar.gui.foundation.core;

// Interface: presentation/history_hint_geometry.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

    struct HistoryHintMeasurements {
      float key = 0;
      float word = 0;
    };

    struct HistoryHintGeometry {
      static constexpr float padding = 6;
      static constexpr float word_gap = 6;
      static constexpr float minimum_key_width = 22;
      static constexpr float key_padding = 10;
      static constexpr float minimum_key_height = 20;
      static constexpr float key_vertical_padding = 4;
      static constexpr float corner_radius = 4;
      static constexpr float key_ring_alpha = 0.2F;
      static constexpr float key_text_alpha = 0.7F;
      static constexpr float ring_width = 1;

      Rect bounds;
      Rect keycap;
      Rect key_text;
      Rect word;

      [[nodiscard]] static float width(ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept;

      [[nodiscard]] static HistoryHintGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept;

      // The keycap's height, which fits the small text and never exceeds `available`.
      [[nodiscard]] static float keyHeight(ChromeMetrics chrome, float available) noexcept;

    private:
      [[nodiscard]] static float keyWidth(ChromeMetrics chrome, float measured) noexcept;
    };

  }
}
