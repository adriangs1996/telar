export module telar.gui.foundation.core:theme;

import std;

import telar.base.text;
import telar.wire.vocabulary;

// Interface: core/background_opacity.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct BackgroundOpacity {
      enum class Surface : std::size_t {
        sidebar,
        topbar,
        bottombar,
        workspace,
        pane,
      };
      static constexpr std::array<const char*, 5> names{"sidebar", "topbar", "bottombar", "workspace", "pane"};
      std::array<std::optional<float>, names.size()> overrides{};

      [[nodiscard]] float resolve(Surface surface, float fallback) const noexcept;

      [[nodiscard]] float minimum(float fallback) const noexcept;
    };

  }
}

// Interface: core/theme_values.cppm
export {
  namespace telar::gui::inline foundation::inline core {

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
      cybervenom,
      zenburn,
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

    inline constexpr std::array theme_names{"shade", "vesper", "catppuccin", "tokyo_night", "pierre_dark", "pierre_dark_soft", "kanagawa", "kanagawa_dragon", "terminal", "cybervenom", "zenburn"};
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

      bool operator==(const TerminalThemeValues&) const = default;
    };

    struct SyntaxStyleValues {
      CellColor color;
      bool italic = false;
      bool bold = false;

      bool operator==(const SyntaxStyleValues&) const = default;
    };

    struct ThemeValues {
      ThemeName base = ThemeName::terminal;
      std::array<CellColor, palette_names.size()> palette{};
      TerminalThemeValues terminal;
      std::array<std::optional<SyntaxStyleValues>, syntax_names.size()> syntax_styles{};

      [[nodiscard]] CellColor color(PaletteRole role) const noexcept;

      [[nodiscard]] SyntaxStyleValues syntaxStyle(SyntaxRole role) const noexcept;

      bool operator==(const ThemeValues&) const = default;
    };

    struct ThemeSelection {
      ThemeValues base;
      std::optional<ThemeValues> light;
      std::optional<ThemeValues> dark;

      [[nodiscard]] ThemeValues resolve(Appearance appearance, const std::optional<ThemeValues>& locked = {}) const noexcept;
    };

  }
}

// Interface: core/color.cppm
export {
  namespace telar::gui::inline foundation::inline core {

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

      bool operator==(const Color&) const = default;
    };

    // Zenburn's projected colors, so a window paints the default theme before its configuration loads.
    struct DefaultTheme {
      static constexpr Color background = Color::rgb(0x2b2b2b);
      static constexpr Color foreground = Color::rgb(0xdcdccc);
      static constexpr Color surface = Color::rgb(0x383838);
      static constexpr Color elevated = Color::rgb(0x4f4f4f);
      static constexpr Color border = Color::rgb(0x5f5f5f);
      static constexpr Color muted = Color::rgb(0x989890);
      static constexpr Color accent = Color::rgb(0xf0dfaf);
      static constexpr Color selection = elevated;
      static constexpr Color cursor = Color::rgb(0xffffef);
      static constexpr Color success = Color::rgb(0x8fb28f);
      static constexpr Color warning = Color::rgb(0xf0dfaf);
      static constexpr Color failure = Color::rgb(0xe37170);
      static constexpr std::size_t palette_size = 16;
      static constexpr std::array<Color, palette_size> palette{
          Color::rgb(0x4f4f4f),
          Color::rgb(0xcc9393),
          Color::rgb(0x8fb28f),
          Color::rgb(0xe0cf9f),
          Color::rgb(0x94bff3),
          Color::rgb(0xdc8cc3),
          Color::rgb(0x8cd0d3),
          Color::rgb(0xdcdccc),
          Color::rgb(0x709080),
          Color::rgb(0xdca3a3),
          Color::rgb(0xafd8af),
          Color::rgb(0xf0dfaf),
          Color::rgb(0xbde0f3),
          Color::rgb(0xec93d3),
          Color::rgb(0x93e0e3),
          Color::rgb(0xffffef),
      };
    };

    struct Theme {
      ThemeName name = ThemeName::zenburn;
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
      // Syntax colors for text the GUI highlights itself, such as the prompt editor.
      std::array<CellColor, syntax_names.size()> syntax{};

      [[nodiscard]] Color chromeColor(PaletteRole role) const noexcept;

      bool operator==(const Theme&) const = default;

      [[nodiscard]] Color resolve(const CellColor& color, Color fallback) const noexcept;
    };

    bool hasAttribute(const CellStyle& style, CellAttribute attribute) noexcept;

  }
}

// Interface: core/color_name.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct ColorName {
      using Value = std::variant<CellColor, PaletteRole>;

      [[nodiscard]] static std::optional<Value> parse(std::string_view name) noexcept;

    private:
      [[nodiscard]] static bool sameRole(std::string_view left, std::string_view right) noexcept;

      [[nodiscard]] static std::optional<Value> literal(std::string_view name) noexcept;
    };

  }
}

// Interface: presentation/theme.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    Color themeRgb(ThemeRgb bytes) noexcept;
    Theme projectTheme(const ThemeValues& values) noexcept;

  }
}
