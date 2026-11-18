module telar.config.gui;

import std;
import telar.lua;
import telar.base.ds;

namespace telar::runtime::config {

  GuiSettings GuiReader::read(const lua::Value& gui) {
    GuiSettings settings;

    if (!gui.present()) {
      return settings;
    }

    gui.onlyFields({"font", "cursor", "window", "chrome", "sidebar", "max_fps", "opacity", "scroll"});
    font(gui.field("font"), settings.font);
    cursor(gui.field("cursor"), settings.cursor);
    scroll(gui.field("scroll"), settings.scroll);
    window(gui.field("window"), settings.window);
    chrome(gui.field("chrome"), settings);
    sidebar(gui.field("sidebar"), settings.sidebar);
    opacity(gui.field("opacity"), settings.opacity);
    settings.max_fps = optionalWhole<std::uint16_t>(gui.field("max_fps"), GuiBounds::max_fps);
    return settings;
  }

  void GuiReader::font(const lua::Value& table, GuiSettings::Font& font) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"family", "style", "size", "line_height", "letter_spacing", "thicken", "thicken_strength", "hinting"});
    font.family = text(table.field("family"));
    font.style = text(table.field("style"));
    font.size = optionalNumber(table.field("size"), GuiBounds::font_size);
    font.line_height = optionalNumber(table.field("line_height"), GuiBounds::line_height);
    font.letter_spacing = optionalNumber(table.field("letter_spacing"), GuiBounds::letter_spacing);
    font.thicken = optionalBoolean(table.field("thicken"));
    font.thicken_strength = optionalWhole<std::uint8_t>(table.field("thicken_strength"), GuiBounds::thicken_strength);
    font.hinting = optionalChoice<FontHinting>(table.field("hinting"), font_hinting_names);
  }

  ds::Option<GuiSettings::FontName> GuiReader::text(const lua::Value& value) {
    optionalUtf8Text(value, GuiBounds::font_name_bytes);
    if (!value.present()) {
      return ds::none;
    }

    GuiSettings::FontName name;

    name.assign(value.string());
    return name;
  }

  void GuiReader::cursor(const lua::Value& table, GuiSettings::Cursor& cursor) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"style", "blink", "blink_interval_ms"});
    cursor.style = optionalChoice<CursorStyle>(table.field("style"), cursor_style_names);
    cursor.blink = optionalBoolean(table.field("blink"));
    cursor.blink_interval_ms = optionalWhole<std::uint16_t>(table.field("blink_interval_ms"), GuiBounds::blink_interval_ms);
  }

  void GuiReader::scroll(const lua::Value& table, GuiSettings::Scroll& scroll) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"smooth", "wheel_ms", "overscan", "sticky_headers"});
    scroll.smooth = optionalBoolean(table.field("smooth"));
    scroll.wheel_ms = optionalWhole<std::uint16_t>(table.field("wheel_ms"), GuiBounds::wheel_ms);
    scroll.overscan = optionalNumber(table.field("overscan"), GuiBounds::overscan);
    scroll.sticky_headers = optionalBoolean(table.field("sticky_headers"));
  }

  void GuiReader::window(const lua::Value& table, GuiSettings::Window& window) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"background_opacity", "background_blur", "titlebar", "padding"});
    window.background_opacity = optionalNumber(table.field("background_opacity"), GuiBounds::opacity);
    window.titlebar = optionalBoolean(table.field("titlebar"));
    const auto blur = table.field("background_blur");
    if (blur.is(LUA_TBOOLEAN)) {
      window.blur = blur.boolean(false);
    } else {
      window.blur_radius = optionalWhole<std::uint8_t>(blur, GuiBounds::background_blur);
    }

    const auto padding = table.field("padding");
    if (padding.present()) {
      padding.onlyFields({"x", "y"});
      window.padding_x = optionalNumber(padding.field("x"), GuiBounds::padding);
      window.padding_y = optionalNumber(padding.field("y"), GuiBounds::padding);
    }
  }

  void GuiReader::chrome(const lua::Value& table, GuiSettings& settings) {
    if (table.present()) {
      table.onlyFields({"scale"});
      settings.chrome_scale = optionalNumber(table.field("scale"), GuiBounds::chrome_scale);
    }
  }

  void GuiReader::opacity(const lua::Value& table, ds::Array<ds::Option<double>, surface_names.size()>& opacity) {
    if (!table.present()) {
      return;
    }

    table.onlyFields(surface_names);
    for (std::size_t index = 0; index < surface_names.size(); ++index) {
      opacity.atMut(index) = optionalNumber(table.field(surface_names[index].data()), GuiBounds::opacity);
    }
  }

  void GuiReader::sidebar(const lua::Value& table, GuiSettings::Sidebar& sidebar) {
    if (table.present()) {
      table.onlyFields({"width"});
      const auto width = table.field("width");
      if (width.is(LUA_TSTRING)) {
        if (width.string() != "auto") {
          width.fail("must be a number or \"auto\"");
        }

        sidebar.automatic = true;
      } else {
        sidebar.width = optionalNumber(width, GuiBounds::sidebar_width);
      }
    }
  }

  ThemeSelectionSettings ThemeReader::selection(const lua::Value& configuration) {
    ThemeSelectionSettings result;
    const auto theme = configuration.field("theme");
    const auto client = configuration.field("client");
    if (client.is(LUA_TTABLE)) {
      const auto alias = client.field("theme");
      if (theme.present() && alias.present()) {
        theme.fail("cannot be combined with client.theme");
      }

      result.base = read(alias);
      appearance(client.field("appearance"), result);
    }

    if (theme.present()) {
      result.base = read(theme);
    }

    return result;
  }

  ds::Option<ThemeSettings> ThemeReader::read(const lua::Value& theme) {
    if (!theme.present()) {
      return ds::none;
    }

    ThemeSettings result;

    if (theme.is(LUA_TSTRING)) {
      result.preset = preset(theme);
      return result;
    }

    theme.onlyFields({"base", "colors", "terminal", "syntax"});
    result.preset = preset(theme.field("base"));
    colors(theme.field("colors"), result.colors);
    terminal(theme.field("terminal"), result.terminal);
    syntax(theme.field("syntax"), result.syntax);
    return result;
  }

  ds::Option<std::string_view> ThemeReader::preset(const lua::Value& value) {
    if (!value.present()) {
      return ds::none;
    }

    const auto text = value.string();
    const auto* const found = std::ranges::find_if(presets, [&](const auto& preset) {
      return text.size() == preset.first.size() && std::equal(text.begin(), text.end(), preset.first.begin(), [](char left, char right) {
        return asciiLower(left) == right;
      });
    });
    if (found == presets.end()) {
      value.fail("names an unknown theme");
    }

    return found->second;
  }

  ThemeColor ThemeReader::color(const lua::Value& value, bool allow_default) {
    const auto text = value.string();
    if (allow_default && text == "default") {
      return {};
    }

    if (text.size() != 7 || text.front() != '#') {
      value.fail("must be an RGB hexadecimal color");
    }

    ThemeRgb rgb{};

    for (std::size_t channel = 0; channel < rgb.size(); ++channel) {
      for (const auto digit : text.substr(1 + (channel * 2), 2)) {
        const auto lower = asciiLower(digit);
        const bool decimal = lower >= '0' && lower <= '9';
        if (!decimal && (lower < 'a' || lower > 'f')) {
          value.fail("contains an invalid hexadecimal digit");
        }

        rgb.atMut(channel) = static_cast<std::uint8_t>((rgb[channel] << 4) | (decimal ? lower - '0' : lower - 'a' + 10));
      }
    }

    return {.rgb = rgb};
  }

  ds::Option<ThemeRgb> ThemeReader::rgb(const lua::Value& value) {
    return value.present() ? color(value, false).rgb : ds::none;
  }

  void ThemeReader::colors(const lua::Value& table, ds::Array<ds::Option<ThemeColor>, theme_color_names.size()>& colors) {
    if (!table.present()) {
      return;
    }

    table.onlyFields(theme_color_names);
    for (std::size_t index = 0; index < theme_color_names.size(); ++index) {
      const auto value = table.field(theme_color_names[index].data());
      if (value.present()) {
        colors.atMut(index) = color(value, true);
      }
    }
  }

  void ThemeReader::terminal(const lua::Value& table, ThemeSettings::Terminal& terminal) {
    if (!table.present()) {
      return;
    }

    table.onlyFields({"foreground", "background", "palette", "cursor_color", "cursor_text_color"});
    terminal.foreground = rgb(table.field("foreground"));
    terminal.background = rgb(table.field("background"));
    terminal.cursor_color = rgb(table.field("cursor_color"));
    terminal.cursor_text_color = rgb(table.field("cursor_text_color"));
    const auto palette = table.field("palette");
    if (!palette.present()) {
      return;
    }

    if (palette.arraySize() != ThemeSettings::Terminal::palette_size) {
      palette.fail("must contain 16 RGB colors");
    }

    auto& entries = terminal.palette.emplace();

    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries.atMut(index) = *color(palette.element(static_cast<lua_Integer>(index) + 1), false).rgb;
    }
  }

  void ThemeReader::syntax(const lua::Value& table, ds::Array<ds::Option<ThemeSettings::Syntax>, theme_syntax_names.size()>& syntax) {
    if (!table.present()) {
      return;
    }

    table.onlyFields(theme_syntax_names);
    for (std::size_t index = 0; index < theme_syntax_names.size(); ++index) {
      const auto style = table.field(theme_syntax_names[index].data());
      if (!style.present()) {
        continue;
      }

      auto& result = syntax.atMut(index).emplace();

      if (style.is(LUA_TTABLE)) {
        style.onlyFields({"fg", "italic", "bold"});
        const auto foreground = style.field("fg");
        if (foreground.present()) {
          result.color = color(foreground, true);
        }

        result.italic = optionalBoolean(style.field("italic"));
        result.bold = optionalBoolean(style.field("bold"));
      } else {
        result.color = color(style, true);
      }
    }
  }

  void ThemeReader::appearance(const lua::Value& table, ThemeSelectionSettings& selection) {
    if (table.present()) {
      table.onlyFields({"light", "dark"});
      selection.light = read(table.field("light"));
      selection.dark = read(table.field("dark"));
    }
  }

}
