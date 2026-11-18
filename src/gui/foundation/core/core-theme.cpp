module telar.gui.foundation.core;

import std;

import telar.base.text;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::inline foundation::inline core {

  float BackgroundOpacity::resolve(Surface surface, float fallback) const noexcept {
    return overrides[static_cast<std::size_t>(surface)].valueOr(fallback);
  }

  float BackgroundOpacity::minimum(float fallback) const noexcept {
    auto result = 1.0F;

    for (std::size_t index = 0; index < names.size(); ++index) {
      result = std::min(result, resolve(static_cast<Surface>(index), fallback));
    }

    return result;
  }

  CellColor ThemeValues::color(PaletteRole role) const noexcept {
    return palette[static_cast<std::size_t>(role)];
  }

  SyntaxStyleValues ThemeValues::syntaxStyle(SyntaxRole role) const noexcept {
    const auto index = static_cast<std::size_t>(role);
    constexpr std::array defaults{PaletteRole::text, PaletteRole::mauve, PaletteRole::green, PaletteRole::peach, PaletteRole::subtext0, PaletteRole::peach, PaletteRole::peach, PaletteRole::teal, PaletteRole::blue, PaletteRole::yellow, PaletteRole::text, PaletteRole::text, PaletteRole::mauve, PaletteRole::subtext0, PaletteRole::subtext0};

    return syntax_styles[index].valueOr(SyntaxStyleValues{.color = color(defaults[index])});
  }

  ThemeValues ThemeSelection::resolve(Appearance appearance, const ds::Option<ThemeValues>& locked) const noexcept {
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

  Color Theme::chromeColor(PaletteRole role) const noexcept {
    const bool background_role = role == PaletteRole::panel_bg || role == PaletteRole::surface0 || role == PaletteRole::surface1 || role == PaletteRole::surface_dim;

    return resolve(chrome[static_cast<std::size_t>(role)], background_role ? background : foreground);
  }

  Color Theme::resolve(const CellColor& color, Color fallback) const noexcept {
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

  bool hasAttribute(const CellStyle& style, CellAttribute attribute) noexcept {
    return (style.flags & static_cast<std::uint16_t>(attribute)) != 0;
  }

  ds::Option<ColorName::Value> ColorName::parse(std::string_view name) noexcept {
    if (runtime::asciiEqualIgnoreCase(name, "default")) {
      return CellColor{};
    }

    for (std::size_t index = 0; index < palette_names.size(); ++index) {
      if (sameRole(name, palette_names[index])) {
        return static_cast<PaletteRole>(index);
      }
    }

    return literal(name);
  }

  bool ColorName::sameRole(std::string_view left, std::string_view right) noexcept {
    if (left.size() != right.size()) {
      return false;
    }

    for (std::size_t index = 0; index < left.size(); ++index) {
      const auto normalize = [](char byte) {
        return byte == '-' ? '_' : runtime::asciiLower(byte);
      };
      if (normalize(left[index]) != normalize(right[index])) {
        return false;
      }
    }

    return true;
  }

  ds::Option<ColorName::Value> ColorName::literal(std::string_view name) noexcept {
    constexpr std::string_view pattern = "#RRGGBB";
    constexpr std::string_view digits = "0123456789abcdef";

    if (name.size() != pattern.size() || name.front() != '#') {
      return ds::none;
    }

    name.remove_prefix(1);
    const bool negative = name.front() == '-';
    if (negative || name.front() == '+') {
      name.remove_prefix(1);
    }

    if (name.front() == '_' || name.back() == '_') {
      return ds::none;
    }

    std::uint32_t value = 0;

    for (const auto byte : name) {
      if (byte == '_') {
        continue;
      }

      const auto digit = digits.find(runtime::asciiLower(byte));
      if (digit == std::string_view::npos || (negative && digit != 0)) {
        return ds::none;
      }

      value = (value * static_cast<std::uint32_t>(digits.size())) + static_cast<std::uint32_t>(digit);
    }

    constexpr unsigned channel_bits = 8;

    return CellColor{.kind = CellColor::Kind::rgb, .channels = {static_cast<Byte>(value >> (channel_bits * 2)), static_cast<Byte>(value >> channel_bits), static_cast<Byte>(value)}};
  }

  Color themeRgb(ThemeRgb bytes) noexcept {
    constexpr unsigned channel_bits = 8;

    return Color::rgb((static_cast<unsigned>(bytes[0]) << (channel_bits * 2)) | (static_cast<unsigned>(bytes[1]) << channel_bits) | bytes[2]);
  }

  Theme projectTheme(const ThemeValues& values) noexcept {
    Theme result;

    result.name = values.base;
    result.foreground = themeRgb(values.terminal.foreground);
    result.background = themeRgb(values.terminal.background);
    std::ranges::transform(values.terminal.palette, result.palette.begin(), themeRgb);
    result.cursor = values.terminal.cursor_color ? themeRgb(*values.terminal.cursor_color) : result.foreground;
    result.cursor_text = values.terminal.cursor_text_color ? ds::Option{themeRgb(*values.terminal.cursor_text_color)} : ds::none;
    result.chrome = values.palette;
    for (std::size_t index = 0; index < result.syntax.size(); ++index) {
      result.syntax[index] = values.syntaxStyle(static_cast<SyntaxRole>(index)).color;
    }

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
