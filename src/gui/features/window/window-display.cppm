// The window's measures on a display: its surfaces' colors and the geometry its density and
// configuration give it.
export module telar.gui.features.window:display;

import std;

import telar.gui.foundation.core;

// Interface: presentation/chrome_surfaces.cppm
export {
  namespace telar::gui::features::window {

    // Background alphas are final surface opacities, not stacked tints.
    struct ChromeSurfaces {
      Color sidebar;
      Color topbar;
      Color bottombar;
      Color workbench;
      Color pane;
      Color text;

      [[nodiscard]] static ChromeSurfaces derive(const Theme& theme, float fallback, const BackgroundOpacity& opacity = {}) noexcept;

    private:
      [[nodiscard]] static Color alpha(Color color, float value) noexcept;
      [[nodiscard]] static Color mix(Color base, Color ink, float amount) noexcept;
    };

  }
}

// Interface: presentation/display_metrics.cppm
export {
  namespace telar::gui::features::window {

    struct DisplayMetrics {
      double density = 1;
      Viewport viewport{};
      ChromeMetrics chrome{};
      WindowGeometry geometry{};

      [[nodiscard]] static DisplayMetrics resolve(const Configuration& configuration, Viewport logical_viewport, const CellMetrics& cells, double density);

    private:
      [[nodiscard]] static std::uint32_t physicalExtent(std::uint32_t logical, double density);
    };

  }
}
