#pragma once

#include "core/theme_values.hpp"
#include "telar_lua/value.hpp"
#include "themes.hpp"
#include <charconv>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <system_error>

namespace telar::gui {

class ThemeReader {
  using Value = runtime::lua::Value;

public:
  static void apply(const Value &root, ThemeSelection &selection) {
    applyTheme(root.field("theme"), selection.base);
    const auto client = root.field("client");
    if (!client.present()) {
      return;
    }

    applyTheme(client.field("theme"), selection.base);
    const auto appearance = client.field("appearance");
    if (!appearance.present()) {
      return;
    }

    applyVariant(appearance.field("light"), selection.light, selection.base);
    applyVariant(appearance.field("dark"), selection.dark, selection.base);
  }

private:
  static CellColor color(const Value &value) {
    const auto text = value.string();
    if (text == "default") {
      return {};
    }

    constexpr std::size_t rgb_text_length = 7;
    if (text.size() != rgb_text_length || text.front() != '#') {
      value.fail("must be an RGB hexadecimal color");
    }

    std::uint32_t rgb = 0;
    constexpr int hexadecimal_base = 16;
    const auto parsed = std::from_chars(text.data() + 1, text.data() + text.size(), rgb, hexadecimal_base);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
      value.fail("must be an RGB hexadecimal color");
    }

    constexpr unsigned channel_bits = 8;

    return {.kind = CellColor::Kind::rgb, .channels = {static_cast<Byte>(rgb >> (channel_bits * 2)), static_cast<Byte>(rgb >> channel_bits), static_cast<Byte>(rgb)}};
  }

  static void applyVariant(const Value &value, std::optional<ThemeValues> &variant, const ThemeValues &base) {
    if (!value.present()) {
      return;
    }

    auto result = variant.value_or(base);
    applyTheme(value, result);
    variant = result;
  }

  static void applyTheme(const Value &value, ThemeValues &theme) {
    if (!value.present()) {
      return;
    }

    if (value.is(LUA_TSTRING)) {
      theme = themeValuesByName(value.string());

      return;
    }

    const auto base = value.field("base");
    if (base.present()) {
      theme = themeValuesByName(base.string());
    }

    const auto colors = value.field("colors");
    if (colors.present()) {
      for (std::size_t index = 0; index < palette_names.size(); ++index) {
        const auto entry = colors.field(palette_names[index]);
        if (entry.present()) {
          theme.palette[index] = color(entry);
        }
      }
    }

    applyTerminal(value.field("terminal"), theme.terminal);
    applySyntax(value.field("syntax"), theme);
  }

  static void applyRgb(const Value &value, ThemeRgb &destination) {
    if (!value.present()) {
      return;
    }

    const auto selected = color(value);
    if (selected.kind != CellColor::Kind::rgb) {
      value.fail("must be an explicit RGB color");
    }

    destination = selected.channels;
  }

  static void applyOptionalRgb(const Value &value, std::optional<ThemeRgb> &destination) {
    if (value.present()) {
      ThemeRgb result{};
      applyRgb(value, result);
      destination = result;
    }
  }

  static void applyTerminal(const Value &value, TerminalThemeValues &terminal) {
    if (!value.present()) {
      return;
    }

    applyRgb(value.field("foreground"), terminal.foreground);
    applyRgb(value.field("background"), terminal.background);
    applyOptionalRgb(value.field("cursor_color"), terminal.cursor_color);
    applyOptionalRgb(value.field("cursor_text_color"), terminal.cursor_text_color);
    const auto palette = value.field("palette");
    if (palette.present()) {
      for (std::size_t index = 0; index < terminal.palette.size(); ++index) {
        applyRgb(palette.element(static_cast<lua_Integer>(index) + 1), terminal.palette[index]);
      }
    }
  }

  static void applySyntax(const Value &value, ThemeValues &theme) {
    if (!value.present()) {
      return;
    }

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      const auto entry = value.field(syntax_names[index]);
      if (!entry.present()) {
        continue;
      }

      auto style = theme.syntaxStyle(static_cast<SyntaxRole>(index));
      if (entry.is(LUA_TTABLE)) {
        const auto foreground = entry.field("fg");
        if (foreground.present()) {
          style.color = color(foreground);
        }

        style.italic = entry.field("italic").boolean(style.italic);
        style.bold = entry.field("bold").boolean(style.bold);
      } else {
        style.color = color(entry);
      }

      theme.syntax_styles[index] = style;
    }
  }
};

}
