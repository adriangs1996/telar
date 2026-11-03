#pragma once

#include "telar_client/serializers/telar_cells.hpp"
#include "theme_values.hpp"
#include <array>
#include <cstddef>
#include <optional>

namespace telar::gui {

struct Color {
  float r = 0;
  float g = 0;
  float b = 0;
  float a = 1;

  static constexpr Color rgb(std::uint32_t rgb, float alpha = 1) noexcept {
    constexpr float channel_max = 255;
    constexpr unsigned channel_bits = 8;
    constexpr unsigned channel_mask = 255;

    return {.r = static_cast<float>((rgb >> (channel_bits * 2)) & channel_mask) / channel_max, .g = static_cast<float>((rgb >> channel_bits) & channel_mask) / channel_max, .b = static_cast<float>(rgb & channel_mask) / channel_max, .a = alpha};
  }

  bool operator==(const Color &) const = default;
};

struct DefaultTheme {
  static constexpr Color background = Color::rgb(0x211b2f);
  static constexpr Color foreground = Color::rgb(0xaba8b6);
  static constexpr Color surface = Color::rgb(0x312b3e);
  static constexpr Color elevated = Color::rgb(0x373245);
  static constexpr Color border = Color::rgb(0x383546);
  static constexpr Color muted = Color::rgb(0x8e899d);
  static constexpr Color accent = Color::rgb(0xaa87f5);
  static constexpr Color selection = elevated;
  static constexpr Color cursor = accent;
  static constexpr Color success = Color::rgb(0x5fb095);
  static constexpr Color warning = Color::rgb(0xd9cc7e);
  static constexpr Color failure = Color::rgb(0xf37986);
  static constexpr std::size_t palette_size = 16;
  static constexpr std::array<Color, palette_size> palette{
      Color::rgb(0x383546),
      Color::rgb(0xf37986),
      Color::rgb(0x5fb095),
      Color::rgb(0xd9cc7e),
      Color::rgb(0x99baf8),
      Color::rgb(0xaa87f5),
      Color::rgb(0x82c3d3),
      Color::rgb(0xaba8b6),
      Color::rgb(0x7c7690),
      Color::rgb(0xfea9af),
      Color::rgb(0x99c2ac),
      Color::rgb(0xe5ca93),
      Color::rgb(0xb8d2ff),
      Color::rgb(0xc7b2ff),
      Color::rgb(0xb3d7e1),
      Color::rgb(0xe5e3ee),
  };
};

struct Theme {
  Color background = DefaultTheme::background;
  Color foreground = DefaultTheme::foreground;
  Color surface = DefaultTheme::surface;
  Color elevated = DefaultTheme::elevated;
  Color border = DefaultTheme::border;
  Color muted = DefaultTheme::muted;
  Color accent = DefaultTheme::accent;
  Color selection = DefaultTheme::selection;
  Color cursor = DefaultTheme::cursor;
  std::optional<Color> cursor_text = DefaultTheme::background;
  Color success = DefaultTheme::success;
  Color warning = DefaultTheme::warning;
  Color failure = DefaultTheme::failure;
  std::array<Color, DefaultTheme::palette_size> palette = DefaultTheme::palette;
  std::array<CellColor, palette_names.size()> chrome{};

  [[nodiscard]] Color chromeColor(PaletteRole role) const noexcept {
    const bool background_role = role == PaletteRole::panel_bg || role == PaletteRole::surface0 || role == PaletteRole::surface1 || role == PaletteRole::surface_dim;

    return resolve(chrome[static_cast<std::size_t>(role)], background_role ? background : foreground);
  }

  bool operator==(const Theme &) const = default;

  [[nodiscard]] Color resolve(const CellColor &color, Color fallback) const noexcept {
    if (color.kind == CellColor::Kind::default_color) {
      return fallback;
    }

    constexpr unsigned channel_bits = 8;
    if (color.kind == CellColor::Kind::rgb) {
      return Color::rgb((static_cast<unsigned>(color.channels[0]) << (channel_bits * 2)) | (static_cast<unsigned>(color.channels[1]) << channel_bits) | color.channels[2]);
    }

    const auto index = color.channels[0];
    if (index < palette.size()) {
      return palette[index];
    }

    constexpr unsigned cube_start = 16;
    constexpr unsigned cube_side = 6;
    constexpr unsigned gray_start = 232;
    constexpr unsigned gray_base = 8;
    constexpr unsigned gray_step = 10;
    constexpr float channel_max = 255;

    if (index >= gray_start) {
      const auto gray = static_cast<float>(gray_base + ((index - gray_start) * gray_step)) / channel_max;

      return {.r = gray, .g = gray, .b = gray, .a = 1};
    }

    const auto component = [](unsigned step) {
      constexpr float base = 55;
      constexpr float increment = 40;

      return step == 0 ? 0.0F : (base + (static_cast<float>(step) * increment)) / channel_max;
    };

    const auto cube = index - cube_start;

    return {.r = component(cube / (cube_side * cube_side)), .g = component(cube / cube_side % cube_side), .b = component(cube % cube_side), .a = 1};
  }
};

inline bool hasAttribute(const CellStyle &style, CellAttribute attribute) noexcept {
  return (style.flags & static_cast<std::uint16_t>(attribute)) != 0;
}

}
