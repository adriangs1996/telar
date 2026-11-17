// The status of a link being opened, over the window.
export module telar.gui.features.terminal.links:presentation;

import std;

import telar.gui.foundation.core;

// Interface: presentation/link_status_geometry.cppm
export {
  namespace telar::gui::features::terminal::links {

    struct LinkStatusGeometry {
      static constexpr float dim_alpha = 0.6F;
      static constexpr float line_height_factor = 1.5F;
      static constexpr float line_gap = 6;
      static constexpr float inset = 24;

      Rect bounds;
      Rect headline;
      Rect detail;

      [[nodiscard]] static LinkStatusGeometry measure(Rect area, const ChromeMetrics& chrome, bool has_detail) noexcept;
    };

  }
}
