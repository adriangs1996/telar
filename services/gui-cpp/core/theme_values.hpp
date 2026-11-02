#pragma once

#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

enum class ThemeName : std::uint8_t {
  shade,
  vesper,
  catppuccin,
  tokyo_night,
  pierre_dark,
  pierre_dark_soft,
  kanagawa,
  kanagawa_dragon,
  terminal,
};

enum class Appearance : std::uint8_t {
  unknown,
  light,
  dark,
};

enum class PaletteRole : std::uint8_t {
  accent,
  panel_bg,
  surface0,
  surface1,
  surface_dim,
  overlay0,
  overlay1,
  text,
  subtext0,
  mauve,
  green,
  yellow,
  red,
  blue,
  teal,
  peach,
};

enum class SyntaxRole : std::uint8_t {
  plain,
  keyword,
  string,
  number,
  comment,
  constant,
  builtin_constant,
  builtin,
  func,
  type,
  parameter,
  property,
  namespace_name,
  operator_name,
  punctuation,
};

inline constexpr std::array theme_names{"shade", "vesper", "catppuccin", "tokyo_night", "pierre_dark", "pierre_dark_soft", "kanagawa", "kanagawa_dragon", "terminal"};
inline constexpr std::array palette_names{"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
inline constexpr std::array syntax_names{"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"};

using ThemeRgb = std::array<Byte, 3>;

struct TerminalThemeValues {
  ThemeRgb foreground{};
  ThemeRgb background{};
  std::optional<ThemeRgb> cursor_color;
  std::optional<ThemeRgb> cursor_text_color;
  static constexpr std::size_t palette_size = 16;
  std::array<ThemeRgb, palette_size> palette{};

  bool operator==(const TerminalThemeValues &) const = default;
};

struct SyntaxStyleValues {
  CellColor color;
  bool italic = false;
  bool bold = false;

  bool operator==(const SyntaxStyleValues &) const = default;
};

struct ThemeValues {
  ThemeName base = ThemeName::terminal;
  std::array<CellColor, palette_names.size()> palette{};
  TerminalThemeValues terminal;
  std::array<std::optional<SyntaxStyleValues>, syntax_names.size()> syntax_styles{};

  [[nodiscard]] CellColor color(PaletteRole role) const noexcept {
    return palette[static_cast<std::size_t>(role)];
  }

  [[nodiscard]] SyntaxStyleValues syntaxStyle(SyntaxRole role) const noexcept {
    const auto index = static_cast<std::size_t>(role);
    constexpr std::array defaults{PaletteRole::text, PaletteRole::mauve, PaletteRole::green, PaletteRole::peach, PaletteRole::subtext0, PaletteRole::peach, PaletteRole::peach, PaletteRole::teal, PaletteRole::blue, PaletteRole::yellow, PaletteRole::text, PaletteRole::text, PaletteRole::mauve, PaletteRole::subtext0, PaletteRole::subtext0};

    return syntax_styles[index].value_or(SyntaxStyleValues{.color = color(defaults[index])});
  }

  bool operator==(const ThemeValues &) const = default;
};

struct ThemeSelection {
  ThemeValues base;
  std::optional<ThemeValues> light;
  std::optional<ThemeValues> dark;

  [[nodiscard]] ThemeValues resolve(Appearance appearance, const std::optional<ThemeValues> &locked = {}) const noexcept {
    if (locked) {
      return *locked;
    }

    if (appearance == Appearance::light && light) {
      return *light;
    }

    if (appearance == Appearance::dark && dark) {
      return *dark;
    }

    return base;
  }
};

}
