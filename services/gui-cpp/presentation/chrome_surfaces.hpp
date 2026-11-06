#pragma once

#include "core/background_opacity.hpp"
#include "core/color.hpp"

namespace telar::gui {

  // Background alphas are final surface opacities, not stacked tints.
  struct ChromeSurfaces {
    Color sidebar;
    Color topbar;
    Color bottombar;
    Color workbench;
    Color pane;
    Color header;
    Color active_header;
    Color text;

    [[nodiscard]] static ChromeSurfaces derive(const Theme &theme, float fallback, const BackgroundOpacity &opacity = {}) noexcept {
      const auto panel = theme.chromeColor(PaletteRole::panel_bg);
      const auto ink = theme.chromeColor(PaletteRole::text);
      const bool dark = theme.background.r + theme.background.g + theme.background.b < 1.5F;
      const auto gutter_end = Color::rgb(dark ? 0x000000 : 0xffffff);
      const auto text_end = Color::rgb(dark ? 0xffffff : 0x000000);
      const auto navigation = mix(panel, ink, 0.09F);
      const auto pane_opacity = opacity.resolve(BackgroundOpacity::Surface::pane, fallback);

      return {
          .sidebar = alpha(navigation, opacity.resolve(BackgroundOpacity::Surface::sidebar, fallback)),
          .topbar = alpha(navigation, opacity.resolve(BackgroundOpacity::Surface::topbar, fallback)),
          .bottombar = alpha(panel, opacity.resolve(BackgroundOpacity::Surface::bottombar, fallback)),
          .workbench = alpha(mix(theme.background, gutter_end, 0.28F), opacity.resolve(BackgroundOpacity::Surface::workspace, fallback)),
          .pane = alpha(panel, pane_opacity),
          .header = alpha(mix(panel, ink, 0.055F), pane_opacity),
          .active_header = alpha(mix(panel, ink, 0.09F), pane_opacity),
          .text = mix(ink, text_end, 0.2F),
      };
    }

  private:
    [[nodiscard]] static Color alpha(Color color, float value) noexcept {
      color.a = value;
      return color;
    }

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
