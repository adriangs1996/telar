#pragma once

#include "telar_base/text/ascii.hpp"
#include "telar_config/value_constraints.hpp"

namespace telar::runtime::config {

class ThemeValidator {
public:
  static void selection(const lua::Value &configuration) {
    const auto theme = configuration.field("theme");
    const auto client = configuration.field("client");
    if (client.is(LUA_TTABLE)) {
      const auto alias = client.field("theme");
      if (theme.present() && alias.present()) {
        theme.fail("cannot be combined with client.theme");
      }
      validate(alias);
      appearance(client.field("appearance"));
    }

    validate(theme);
  }

  static void validate(const lua::Value &theme) {
    if (!theme.present()) {
      return;
    }
    if (theme.is(LUA_TSTRING)) {
      preset(theme);
      return;
    }

    theme.onlyFields({"base", "colors", "terminal", "syntax"});
    preset(theme.field("base"));
    colors(theme.field("colors"));
    terminal(theme.field("terminal"));
    syntax(theme.field("syntax"));
  }

private:
  static void preset(const lua::Value &value) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    constexpr std::string_view names[]{"cybervenom", "shade", "osaka-jade", "osaka_jade", "osakajade", "vesper", "catppuccin", "catppuccin-mocha", "mocha", "tokyo-night", "tokyonight", "tokyo_night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-wave", "kanagawa_wave", "kanagawa-dragon", "kanagawa_dragon", "terminal", "default"};
    const bool found = std::ranges::any_of(names, [&](std::string_view name) {
      return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) { return asciiLower(left) == right; });
    });
    if (!found) {
      value.fail("names an unknown theme");
    }
  }

  static void color(const lua::Value &value, bool allow_default) {
    if (!value.present()) {
      return;
    }

    const auto text = value.string();
    if (allow_default && text == "default") {
      return;
    }
    if (text.size() != 7 || text.front() != '#') {
      value.fail("must be an RGB hexadecimal color");
    }
    if (!std::ranges::all_of(text.substr(1), [](char byte) { return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f'); })) {
      value.fail("contains an invalid hexadecimal digit");
    }
  }

  static void colors(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"});
    table.eachField([](std::string_view, const lua::Value &value) { color(value, true); });
  }

  static void terminal(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"foreground", "background", "palette", "cursor_color", "cursor_text_color"});
    for (const auto *name : {"foreground", "background", "cursor_color", "cursor_text_color"}) {
      color(table.field(name), false);
    }
    const auto palette = table.field("palette");
    if (palette.present()) {
      constexpr std::size_t palette_size = 16;
      if (palette.arraySize() != palette_size) {
        palette.fail("must contain 16 RGB colors");
      }
      for (std::size_t index = 1; index <= palette_size; ++index) {
        const auto entry = palette.element(static_cast<lua_Integer>(index));
        entry.string();
        color(entry, false);
      }
    }
  }

  static void syntax(const lua::Value &table) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"});
    table.eachField([](std::string_view, const lua::Value &style) {
      if (style.is(LUA_TTABLE)) {
        style.onlyFields({"fg", "italic", "bold"});
        color(style.field("fg"), true);
        style.field("italic").boolean(false);
        style.field("bold").boolean(false);
      } else {
        color(style, true);
      }
    });
  }

  static void appearance(const lua::Value &table) {
    if (table.present()) {
      table.onlyFields({"light", "dark"});
      validate(table.field("light"));
      validate(table.field("dark"));
    }
  }
};

}
