export module telar.gui.foundation.drawing:chrome_style;

import std;

// Interface: presentation/chrome_style.cppm
export {
  namespace telar::gui::inline foundation::inline drawing {

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
      // The well the top bar's selectors sit on at rest: the machine switch and the workspace
      // track.
      static constexpr float well_alpha = 0.07F;
      // The columns every chrome menu's rows share, the machines' and the workspaces': the
      // inset of their mark, the mark, and the gap before their text.
      static constexpr float menu_row_padding = 8;
      // Above a menu row's first line and below its second.
      static constexpr float menu_row_vertical_padding = 5;
      static constexpr float menu_mark = 24;
      static constexpr float menu_gap = 6;
    };

  }
}
