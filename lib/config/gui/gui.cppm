module;
#include <lua.h>

export module telar.config.gui;

import std;
export import telar.config.core;

// Interface: telar_config/gui_reader.cppm
export {
  namespace telar::runtime::config {

    // What `gui` admits; the GUI's own limits follow these.
    struct GuiBounds {
      static constexpr std::size_t font_name_bytes = 256;
      static constexpr Bounds<double> font_size{6, 96};
      static constexpr Bounds<double> line_height{0.75, 3};
      static constexpr Bounds<double> letter_spacing{-5, 20};
      static constexpr Bounds<double> thicken_strength{0, 255};
      static constexpr Bounds<double> blink_interval_ms{100, 5000};
      static constexpr Bounds<double> wheel_ms{0, 400};
      static constexpr Bounds<double> overscan{0, 4};
      static constexpr Bounds<double> opacity{0, 1};
      static constexpr Bounds<double> background_blur{0, 255};
      static constexpr Bounds<double> padding{0, 256};
      static constexpr Bounds<double> chrome_scale{0.5, 2};
      static constexpr Bounds<double> sidebar_width{220, 800};
      static constexpr Bounds<double> max_fps{30, 240};
    };

    enum class CursorStyle : std::uint8_t {
      block,
      bar,
      underline,
      hollow,
    };

    enum class FontHinting : std::uint8_t {
      native,
      light,
      full,
    };

    inline constexpr std::array<std::string_view, 4> cursor_style_names{"block", "bar", "underline", "hollow"};
    inline constexpr std::array<std::string_view, 3> font_hinting_names{"native", "light", "full"};
    inline constexpr std::array<std::string_view, 5> surface_names{"sidebar", "topbar", "bottombar", "workspace", "pane"};

    // The `gui` table as read: each field the configuration sets, already within its bounds.
    struct GuiSettings {
      using FontName = FixedText<GuiBounds::font_name_bytes>;

      struct Font {
        std::optional<FontName> family;
        std::optional<FontName> style;
        std::optional<double> size;
        std::optional<double> line_height;
        std::optional<double> letter_spacing;
        std::optional<bool> thicken;
        std::optional<std::uint8_t> thicken_strength;
        std::optional<FontHinting> hinting;
      };

      struct Cursor {
        std::optional<CursorStyle> style;
        std::optional<bool> blink;
        std::optional<std::uint16_t> blink_interval_ms;
      };

      struct Scroll {
        std::optional<bool> smooth;
        std::optional<std::uint16_t> wheel_ms;
        std::optional<double> overscan;
        std::optional<bool> sticky_headers;
      };

      struct Window {
        std::optional<double> background_opacity;
        std::optional<bool> titlebar;
        // `background_blur = true` or false, or a radius.
        std::optional<bool> blur;
        std::optional<std::uint8_t> blur_radius;
        std::optional<double> padding_x;
        std::optional<double> padding_y;
      };

      struct Sidebar {
        std::optional<double> width;
        bool automatic = false;
      };

      Font font;
      Cursor cursor;
      Scroll scroll;
      Window window;
      Sidebar sidebar;
      std::optional<double> chrome_scale;
      std::optional<std::uint16_t> max_fps;
      std::array<std::optional<double>, surface_names.size()> opacity{};
    };

    class GuiReader {
    public:
      [[nodiscard]] inline static GuiSettings read(const lua::Value& gui) {
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

    private:
      inline static void font(const lua::Value& table, GuiSettings::Font& font) {
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

      inline static std::optional<GuiSettings::FontName> text(const lua::Value& value) {
        optionalUtf8Text(value, GuiBounds::font_name_bytes);
        if (!value.present()) {
          return std::nullopt;
        }

        GuiSettings::FontName name;

        name.assign(value.string());
        return name;
      }

      inline static void cursor(const lua::Value& table, GuiSettings::Cursor& cursor) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"style", "blink", "blink_interval_ms"});
        cursor.style = optionalChoice<CursorStyle>(table.field("style"), cursor_style_names);
        cursor.blink = optionalBoolean(table.field("blink"));
        cursor.blink_interval_ms = optionalWhole<std::uint16_t>(table.field("blink_interval_ms"), GuiBounds::blink_interval_ms);
      }

      inline static void scroll(const lua::Value& table, GuiSettings::Scroll& scroll) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"smooth", "wheel_ms", "overscan", "sticky_headers"});
        scroll.smooth = optionalBoolean(table.field("smooth"));
        scroll.wheel_ms = optionalWhole<std::uint16_t>(table.field("wheel_ms"), GuiBounds::wheel_ms);
        scroll.overscan = optionalNumber(table.field("overscan"), GuiBounds::overscan);
        scroll.sticky_headers = optionalBoolean(table.field("sticky_headers"));
      }

      inline static void window(const lua::Value& table, GuiSettings::Window& window) {
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

      inline static void chrome(const lua::Value& table, GuiSettings& settings) {
        if (table.present()) {
          table.onlyFields({"scale"});
          settings.chrome_scale = optionalNumber(table.field("scale"), GuiBounds::chrome_scale);
        }
      }

      inline static void opacity(const lua::Value& table, std::array<std::optional<double>, surface_names.size()>& opacity) {
        if (!table.present()) {
          return;
        }

        table.onlyFields(surface_names);
        for (std::size_t index = 0; index < surface_names.size(); ++index) {
          opacity[index] = optionalNumber(table.field(surface_names[index].data()), GuiBounds::opacity);
        }
      }

      inline static void sidebar(const lua::Value& table, GuiSettings::Sidebar& sidebar) {
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
    };

  }
}

// Interface: telar_config/theme_validator.cppm
export {
  namespace telar::runtime::config {

    class ThemeValidator {
    public:
      inline static void selection(const lua::Value& configuration) {
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

      inline static void validate(const lua::Value& theme) {
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
      inline static void preset(const lua::Value& value) {
        if (!value.present()) {
          return;
        }

        const auto text = value.string();
        constexpr std::string_view names[]{"cybervenom", "shade", "vesper", "catppuccin", "catppuccin-mocha", "mocha", "tokyo-night", "tokyonight", "tokyo_night", "pierre-dark", "pierre-dark-soft", "kanagawa", "kanagawa-wave", "kanagawa_wave", "kanagawa-dragon", "kanagawa_dragon", "terminal", "default"};
        const bool found = std::ranges::any_of(names, [&](std::string_view name) {
          return text.size() == name.size() && std::equal(text.begin(), text.end(), name.begin(), [](char left, char right) {
            return asciiLower(left) == right;
          });
        });
        if (!found) {
          value.fail("names an unknown theme");
        }
      }

      inline static void color(const lua::Value& value, bool allow_default) {
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

        if (!std::ranges::all_of(text.substr(1), [](char byte) {
              return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f');
            })) {
          value.fail("contains an invalid hexadecimal digit");
        }
      }

      inline static void colors(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"});
        table.eachField([](std::string_view, const lua::Value& value) {
          color(value, true);
        });
      }

      inline static void terminal(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"foreground", "background", "palette", "cursor_color", "cursor_text_color"});
        for (const auto* name : {"foreground", "background", "cursor_color", "cursor_text_color"}) {
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

      inline static void syntax(const lua::Value& table) {
        if (!table.present()) {
          return;
        }

        table.onlyFields({"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"});
        table.eachField([](std::string_view, const lua::Value& style) {
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

      inline static void appearance(const lua::Value& table) {
        if (table.present()) {
          table.onlyFields({"light", "dark"});
          validate(table.field("light"));
          validate(table.field("dark"));
        }
      }
    };

  }
}
