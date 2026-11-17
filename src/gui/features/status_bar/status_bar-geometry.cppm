// Where the mode bar draws its badge and as many whole hints as fit.
export module telar.gui.features.status_bar:geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

// Interface: presentation/mode_bar_geometry.cppm
export {
  namespace telar::gui::features::status_bar {

    struct ModeBarMeasurements {
      static constexpr std::size_t capacity = 16;
      float title = 0;
      std::array<HistoryHintMeasurements, capacity> hints{};
      std::size_t count = 0;
    };

    // The mode's badge, then its key hints in the history footer's style, as many whole ones as fit.
    struct ModeBarGeometry {
      static constexpr float title_gap = 6;
      static constexpr float hint_gap = 2;

      Rect title;
      std::array<HistoryHintGeometry, ModeBarMeasurements::capacity> hints{};
      std::size_t count = 0;

      [[nodiscard]] static ModeBarGeometry derive(Rect area, ChromeMetrics chrome, const ModeBarMeasurements& measured) noexcept;
    };

  }
}
