#pragma once

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
