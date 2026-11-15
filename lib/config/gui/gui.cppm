export module telar.config.gui;

import std;
import telar.base.text;
import telar.base.memory.containers;
import telar.config.core;
import telar.lua;

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
      [[nodiscard]] static GuiSettings read(const lua::Value& gui);

    private:
      static void font(const lua::Value& table, GuiSettings::Font& font);
      static std::optional<GuiSettings::FontName> text(const lua::Value& value);
      static void cursor(const lua::Value& table, GuiSettings::Cursor& cursor);
      static void scroll(const lua::Value& table, GuiSettings::Scroll& scroll);
      static void window(const lua::Value& table, GuiSettings::Window& window);
      static void chrome(const lua::Value& table, GuiSettings& settings);
      static void opacity(const lua::Value& table, std::array<std::optional<double>, surface_names.size()>& opacity);
      static void sidebar(const lua::Value& table, GuiSettings::Sidebar& sidebar);
    };

  }
}

// Interface: telar_config/theme_reader.cppm
export {
  namespace telar::runtime::config {

    // The names `theme.colors` and `theme.syntax` admit, in the order of the GUI's palette and
    // syntax roles.
    inline constexpr std::array<std::string_view, 16> theme_color_names{"accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
    inline constexpr std::array<std::string_view, 15> theme_syntax_names{"plain", "keyword", "string", "number", "comment", "constant", "builtin_constant", "builtin", "func", "type", "parameter", "property", "namespace", "operator", "punctuation"};

    using ThemeRgb = std::array<std::uint8_t, 3>;

    // A theme color as configured: an RGB value, or the terminal's own color for "default".
    struct ThemeColor {
      std::optional<ThemeRgb> rgb;
    };

    // One theme table as read: the preset it starts from and each value it sets.
    struct ThemeSettings {
      struct Terminal {
        static constexpr std::size_t palette_size = 16;
        std::optional<ThemeRgb> foreground;
        std::optional<ThemeRgb> background;
        std::optional<ThemeRgb> cursor_color;
        std::optional<ThemeRgb> cursor_text_color;
        std::optional<std::array<ThemeRgb, palette_size>> palette;
      };

      struct Syntax {
        std::optional<ThemeColor> color;
        std::optional<bool> italic;
        std::optional<bool> bold;
      };

      // The preset's canonical name, which outlives the configuration.
      std::optional<std::string_view> preset;
      std::array<std::optional<ThemeColor>, theme_color_names.size()> colors{};
      Terminal terminal;
      std::array<std::optional<Syntax>, theme_syntax_names.size()> syntax{};
    };

    // `theme` (or its alias `client.theme`) and the `client.appearance` variants of a
    // configuration or a profile.
    struct ThemeSelectionSettings {
      std::optional<ThemeSettings> base;
      std::optional<ThemeSettings> light;
      std::optional<ThemeSettings> dark;
    };

    class ThemeReader {
    public:
      [[nodiscard]] static ThemeSelectionSettings selection(const lua::Value& configuration);
      [[nodiscard]] static std::optional<ThemeSettings> read(const lua::Value& theme);

    private:
      // Each name a theme may give, with the preset it selects.
      static constexpr std::array<std::pair<std::string_view, std::string_view>, 18> presets{{
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
      }};

      static std::optional<std::string_view> preset(const lua::Value& value);
      static ThemeColor color(const lua::Value& value, bool allow_default);
      static std::optional<ThemeRgb> rgb(const lua::Value& value);
      static void colors(const lua::Value& table, std::array<std::optional<ThemeColor>, theme_color_names.size()>& colors);
      static void terminal(const lua::Value& table, ThemeSettings::Terminal& terminal);
      static void syntax(const lua::Value& table, std::array<std::optional<ThemeSettings::Syntax>, theme_syntax_names.size()>& syntax);
      static void appearance(const lua::Value& table, ThemeSelectionSettings& selection);
    };

  }
}
