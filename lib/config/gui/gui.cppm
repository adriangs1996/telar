export module telar.config.gui;

import std;
import telar.base.memory.containers;
import telar.config.core;
import telar.lua;
import telar.base.ds;
import telar.tbc;

// Interface: telar_config/gui_reader.cppm
export {
  namespace telar::runtime::config {

    // What `gui` admits; the GUI's own limits follow these.
    struct GuiBounds {
      static constexpr std::size_t font_name_bytes = 256;
      static constexpr Bounds<double> font_size{.minimum = 6, .maximum = 96};
      static constexpr Bounds<double> line_height{.minimum = 0.75, .maximum = 3};
      static constexpr Bounds<double> letter_spacing{.minimum = -5, .maximum = 20};
      static constexpr Bounds<double> thicken_strength{.minimum = 0, .maximum = 255};
      static constexpr Bounds<double> blink_interval_ms{.minimum = 100, .maximum = 5000};
      static constexpr Bounds<double> wheel_ms{.minimum = 0, .maximum = 400};
      static constexpr Bounds<double> overscan{.minimum = 0, .maximum = 4};
      static constexpr Bounds<double> opacity{.minimum = 0, .maximum = 1};
      static constexpr Bounds<double> background_blur{.minimum = 0, .maximum = 255};
      static constexpr Bounds<double> padding{.minimum = 0, .maximum = 256};
      static constexpr Bounds<double> chrome_scale{.minimum = 0.5, .maximum = 2};
      static constexpr Bounds<double> sidebar_width{.minimum = 220, .maximum = 800};
      static constexpr Bounds<double> max_fps{.minimum = 30, .maximum = 240};
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

    inline constexpr ds::Array<std::string_view, 4> cursor_style_names{"block", "bar", "underline", "hollow"};
    inline constexpr ds::Array<std::string_view, 3> font_hinting_names{"native", "light", "full"};
    inline constexpr ds::Array<std::string_view, 5> surface_names{"sidebar", "topbar", "bottombar", "workspace", "pane"};

    // The `gui` table as read: each field the configuration sets, already within its bounds.
    struct GuiSettings {
      using FontName = FixedText<GuiBounds::font_name_bytes>;

      struct Font {
        ds::Option<FontName> family;
        ds::Option<FontName> style;
        ds::Option<double> size;
        ds::Option<double> line_height;
        ds::Option<double> letter_spacing;
        ds::Option<bool> thicken;
        ds::Option<std::uint8_t> thicken_strength;
        ds::Option<FontHinting> hinting;
      };

      struct Cursor {
        ds::Option<CursorStyle> style;
        ds::Option<bool> blink;
        ds::Option<std::uint16_t> blink_interval_ms;
      };

      struct Scroll {
        ds::Option<bool> smooth;
        ds::Option<std::uint16_t> wheel_ms;
        ds::Option<double> overscan;
        ds::Option<bool> sticky_headers;
      };

      struct Window {
        ds::Option<double> background_opacity;
        ds::Option<bool> titlebar;
        // `background_blur = true` or false, or a radius.
        ds::Option<bool> blur;
        ds::Option<std::uint8_t> blur_radius;
        ds::Option<double> padding_x;
        ds::Option<double> padding_y;
      };

      struct Sidebar {
        ds::Option<double> width;
        bool automatic = false;
      };

      Font font;
      Cursor cursor;
      Scroll scroll;
      Window window;
      Sidebar sidebar;
      ds::Option<double> chrome_scale;
      ds::Option<std::uint16_t> max_fps;
      ds::Array<ds::Option<double>, surface_names.size()> opacity{};
    };

    class GuiReader {
    public:
      // The settings view the strings the Lua state holds, region `a`.
      [[nodiscard]] static tbc::val_a<GuiSettings> read(const lua::Value& gui);

    private:
      static void font(const lua::Value& table, GuiSettings::Font& font);
      static ds::Option<GuiSettings::FontName> text(const lua::Value& value);
      static void cursor(const lua::Value& table, GuiSettings::Cursor& cursor);
      static void scroll(const lua::Value& table, GuiSettings::Scroll& scroll);
      static void window(const lua::Value& table, GuiSettings::Window& window);
      static void chrome(const lua::Value& table, GuiSettings& settings);
      static void opacity(const lua::Value& table, ds::Array<ds::Option<double>, surface_names.size()>& opacity);
      static void sidebar(const lua::Value& table, GuiSettings::Sidebar& sidebar);
    };

  }
}

// Interface: telar_config/theme_reader.cppm
export {
  namespace telar::runtime::config {

    // The names `theme.colors` and `theme.syntax` admit, in the order of the GUI's palette and
    // syntax roles.
    inline constexpr ds::Array<std::string_view, 16> theme_color_names{"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
    inline constexpr ds::Array<std::string_view, 15> theme_syntax_names{"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"};

    using ThemeRgb = ds::Array<std::uint8_t, 3>;

    // A theme color as configured: an RGB value, or the terminal's own color for "default".
    struct ThemeColor {
      ds::Option<ThemeRgb> rgb;
    };

    // One theme table as read: the preset it starts from and each value it sets.
    struct ThemeSettings {
      struct Terminal {
        static constexpr std::size_t palette_size = 16;
        ds::Option<ThemeRgb> foreground;
        ds::Option<ThemeRgb> background;
        ds::Option<ThemeRgb> cursor_color;
        ds::Option<ThemeRgb> cursor_text_color;
        ds::Option<ds::Array<ThemeRgb, palette_size>> palette;
      };

      struct Syntax {
        ds::Option<ThemeColor> color;
        ds::Option<bool> italic;
        ds::Option<bool> bold;
      };

      // The preset's canonical name, which outlives the configuration.
      ds::Option<std::string_view> preset;
      ds::Array<ds::Option<ThemeColor>, theme_color_names.size()> colors{};
      Terminal terminal;
      ds::Array<ds::Option<Syntax>, theme_syntax_names.size()> syntax{};
    };

    // `theme` (or its alias `client.theme`) and the `client.appearance` variants of a
    // configuration or a profile.
    struct ThemeSelectionSettings {
      ds::Option<ThemeSettings> base;
      ds::Option<ThemeSettings> light;
      ds::Option<ThemeSettings> dark;
    };

    class ThemeReader {
    public:
      // `themes`, the named themes the theme picker lists beside the presets.
      static constexpr std::size_t maximum_named_themes = 64;
      static constexpr std::size_t maximum_theme_name_bytes = 64;

      // The settings view the strings the Lua state holds, region `a`.
      [[nodiscard]] static tbc::val_a<ThemeSelectionSettings> selection(const lua::Value& configuration);
      [[nodiscard]] static tbc::val_a<ds::Option<ThemeSettings>> read(const lua::Value& theme);

      // Hands `consume` each theme of the configuration's `themes` table with its name, in the
      // table's order. Both view the strings the Lua state holds. Stays in the interface because
      // it is a template over the caller's callable.
      template <typename Consume>
      [[tbc::generic]] static void named(const lua::Value& configuration, const Consume& consume) {
        const auto themes = configuration.field("themes");
        if (!themes.present()) {
          return;
        }

        std::size_t count = 0;

        themes.eachField([&](std::string_view name, const lua::Value& theme) {
          if (++count > maximum_named_themes) {
            themes.fail("has more than 64 themes");
          }

          if (!validName(name)) {
            theme.fail("has an invalid name: use 1..64 letters, digits, '-' or '_'");
          }

          consume(name, *read(theme));
        });
      }

    private:
      // Each name a theme may give, with the preset it selects.
      static constexpr ds::Array<std::pair<std::string_view, std::string_view>, 19> presets{
          {
              {"cybervenom", "cybervenom"},
              {"shade", "shade"},
              {"vesper", "vesper"},
              {"catppuccin", "catppuccin"},
              {"catppuccin-mocha", "catppuccin"},
              {"mocha", "catppuccin"},
              {"tokyo-night", "tokyo-night"},
              {"tokyonight", "tokyo-night"},
              {"tokyo_night", "tokyo-night"},
              {"pierre-dark", "pierre-dark"},
              {"pierre-dark-soft", "pierre-dark-soft"},
              {"kanagawa", "kanagawa"},
              {"kanagawa-wave", "kanagawa"},
              {"kanagawa_wave", "kanagawa"},
              {"kanagawa-dragon", "kanagawa-dragon"},
              {"kanagawa_dragon", "kanagawa-dragon"},
              {"terminal", "terminal"},
              {"default", "terminal"},
              {"zenburn", "zenburn"},
          },
      };

      static bool validName(std::string_view name) noexcept;
      static tbc::val_a<ds::Option<std::string_view>> preset(const lua::Value& value);
      static ThemeColor color(const lua::Value& value, bool allow_default);
      static ds::Option<ThemeRgb> rgb(const lua::Value& value);
      static void colors(const lua::Value& table, ds::Array<ds::Option<ThemeColor>, theme_color_names.size()>& colors);
      static void terminal(const lua::Value& table, ThemeSettings::Terminal& terminal);
      static void syntax(const lua::Value& table, ds::Array<ds::Option<ThemeSettings::Syntax>, theme_syntax_names.size()>& syntax);
      static void appearance(const lua::Value& table, tbc::mut_a<ThemeSelectionSettings> selection);
    };

  }
}
