#pragma once

#include "core/color.hpp"
#include "core/theme_values.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>

namespace telar::gui {

inline Color themeRgb(ThemeRgb bytes) noexcept {
  constexpr unsigned channel_bits = 8;

  return Color::rgb((static_cast<unsigned>(bytes[0]) << (channel_bits * 2)) | (static_cast<unsigned>(bytes[1]) << channel_bits) | bytes[2]);
}

inline Theme projectTheme(const ThemeValues &values) noexcept {
  Theme result;
  result.foreground = themeRgb(values.terminal.foreground);
  result.background = themeRgb(values.terminal.background);
  std::ranges::transform(values.terminal.palette, result.palette.begin(), themeRgb);
  result.cursor = values.terminal.cursor_color ? themeRgb(*values.terminal.cursor_color) : result.foreground;
  result.cursor_text = values.terminal.cursor_text_color ? std::optional{themeRgb(*values.terminal.cursor_text_color)} : std::nullopt;
  result.chrome = values.palette;
  result.surface = result.resolve(values.color(PaletteRole::surface0), result.background);
  result.elevated = result.resolve(values.color(PaletteRole::surface1), result.background);
  result.border = result.resolve(values.color(PaletteRole::overlay0), result.foreground);
  result.muted = result.resolve(values.color(PaletteRole::subtext0), result.foreground);
  result.accent = result.resolve(values.color(PaletteRole::accent), result.foreground);
  result.selection = result.elevated;
  result.success = result.resolve(values.color(PaletteRole::green), result.foreground);
  result.warning = result.resolve(values.color(PaletteRole::yellow), result.foreground);
  result.failure = result.resolve(values.color(PaletteRole::red), result.foreground);

  return result;
}

}
