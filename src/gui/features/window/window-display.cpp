module telar.gui.features.window;

import std;
import telar.gui.foundation.core;

namespace telar::gui::features::window {

  ChromeSurfaces ChromeSurfaces::derive(const Theme& theme, float fallback, const BackgroundOpacity& opacity) noexcept {
    const auto panel = theme.chromeColor(PaletteRole::panel_bg);
    const auto ink = theme.chromeColor(PaletteRole::text);
    const bool dark = theme.background.r + theme.background.g + theme.background.b < 1.5F;
    const auto gutter_end = Color::rgb(dark ? 0x000000 : 0xffffff);
    const auto text_end = Color::rgb(dark ? 0xffffff : 0x000000);
    const auto dim = theme.chromeColor(PaletteRole::surface_dim);
    const auto sheet = dim == panel ? mix(panel, gutter_end, 0.28F) : dim;

    return {
        .sidebar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::sidebar, fallback)),
        .topbar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::topbar, fallback)),
        .bottombar = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::bottombar, fallback)),
        .workbench = alpha(sheet, opacity.resolve(BackgroundOpacity::Surface::workspace, fallback)),
        .pane = alpha(panel, opacity.resolve(BackgroundOpacity::Surface::pane, fallback)),
        .text = mix(ink, text_end, 0.7F),
    };
  }

  Color ChromeSurfaces::alpha(Color color, float value) noexcept {
    color.a = value;
    return color;
  }

  Color ChromeSurfaces::mix(Color base, Color ink, float amount) noexcept {
    return {
        .r = base.r + ((ink.r - base.r) * amount),
        .g = base.g + ((ink.g - base.g) * amount),
        .b = base.b + ((ink.b - base.b) * amount),
        .a = 1,
    };
  }

  DisplayMetrics DisplayMetrics::resolve(const Configuration& configuration, Viewport logical_viewport, const CellMetrics& cells, double density) {
    if (!std::isfinite(density) || density <= 0 || density > Viewport::maximum_scale) {
      throw std::invalid_argument{"InvalidDisplayDensity"};
    }

    const Viewport physical{
        .width = physicalExtent(logical_viewport.width, density),
        .height = physicalExtent(logical_viewport.height, density),
        .scale = static_cast<float>(density),
        .controls = physicalExtent(logical_viewport.controls, density),
    };

    const auto chrome = ChromeMetrics::resolve(configuration, physical, cells);

    return {.density = density, .viewport = physical, .chrome = chrome, .geometry = WindowGeometry::measure(configuration, physical, cells, chrome)};
  }

  std::uint32_t DisplayMetrics::physicalExtent(std::uint32_t logical, double density) {
    const auto extent = std::round(logical * density);
    if (extent > std::numeric_limits<std::uint32_t>::max()) {
      throw std::out_of_range{"DisplayExtentOutOfRange"};
    }

    return static_cast<std::uint32_t>(extent);
  }

}
