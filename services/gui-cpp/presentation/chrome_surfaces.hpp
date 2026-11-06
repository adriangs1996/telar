#pragma once

#include "core/color.hpp"

namespace telar::gui {

  // Separate navigation, gutters and pane bands without imposing a palette.
  struct ChromeSurfaces {
    Color navigation;
    Color workbench;
    Color pane;
    Color header;
    Color active_header;

    [[nodiscard]] static ChromeSurfaces derive(const Theme &theme, float opacity) noexcept {
      const auto panel = theme.chromeColor(PaletteRole::panel_bg);
      const auto ink = theme.chromeColor(PaletteRole::text);
      constexpr float navigation_mix = 0.09F;
      constexpr float header_mix = 0.055F;
      constexpr float active_header_mix = 0.09F;
      constexpr float gutter_mix = 0.28F;
      const bool translucent = opacity < 1;
      const auto band = [&](float amount) {
        return translucent ? Color{.r = ink.r, .g = ink.g, .b = ink.b, .a = amount} : mix(panel, ink, amount);
      };
      const auto background = theme.background;
      const auto end = background.r + background.g + background.b < 1.5F ? Color::rgb(0x000000) : Color::rgb(0xffffff);

      return {
          .navigation = band(navigation_mix),
          .workbench = translucent ? Color{.a = 0} : mix(background, end, gutter_mix),
          .pane = translucent ? Color{.a = 0} : panel,
          .header = band(header_mix),
          .active_header = band(active_header_mix),
      };
    }

  private:
    [[nodiscard]] static Color mix(Color base, Color ink, float amount) noexcept {
      return {
          .r = base.r + (ink.r - base.r) * amount,
          .g = base.g + (ink.g - base.g) * amount,
          .b = base.b + (ink.b - base.b) * amount,
          .a = 1,
      };
    }
  };

}
