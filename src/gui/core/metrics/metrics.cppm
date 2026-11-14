module;
#include <cstddef>
#include <cstdint>

export module telar.gui.core.metrics;

import std;

import telar.base.diagnostics;
import telar.base.memory.containers;
import telar.base.text;
import telar.gui.core.primitives;
import telar.wire.vocabulary;

// Interface: core/background_opacity.cppm
export {
  namespace telar::gui {

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
      cybervenom,
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

    inline constexpr std::array theme_names{"shade", "vesper", "catppuccin", "tokyo_night", "pierre_dark", "pierre_dark_soft", "kanagawa", "kanagawa_dragon", "terminal", "cybervenom"};
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

      bool operator==(const Color&) const = default;
    };

    struct DefaultTheme {
      static constexpr Color background = Color::rgb(0x191c22);
      static constexpr Color foreground = Color::rgb(0xd8dee9);
      static constexpr Color surface = Color::rgb(0x242933);
      static constexpr Color elevated = Color::rgb(0x3b4252);
      static constexpr Color border = Color::rgb(0x4c566a);
      static constexpr Color muted = Color::rgb(0x7b88a1);
      static constexpr Color accent = Color::rgb(0x88c0d0);
      static constexpr Color selection = Color::rgb(0x434c5e);
      static constexpr Color cursor = accent;
      static constexpr Color success = Color::rgb(0xa3be8c);
      static constexpr Color warning = Color::rgb(0xebcb8b);
      static constexpr Color failure = Color::rgb(0xbf616a);
      static constexpr std::size_t palette_size = 16;
      static constexpr std::array<Color, palette_size> palette{
          Color::rgb(0x3b4252),
          Color::rgb(0xbf616a),
          Color::rgb(0xa3be8c),
          Color::rgb(0xebcb8b),
          Color::rgb(0x81a1c1),
          Color::rgb(0xb48ead),
          Color::rgb(0x88c0d0),
          Color::rgb(0xe5e9f0),
          Color::rgb(0x616e88),
          Color::rgb(0xbf616a),
          Color::rgb(0xa3be8c),
          Color::rgb(0xebcb8b),
          Color::rgb(0x81a1c1),
          Color::rgb(0xb48ead),
          Color::rgb(0x8fbcbb),
          Color::rgb(0xeceff4),
      };
    };

    struct Theme {
      ThemeName name = ThemeName::shade;
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
  namespace telar::gui {

    struct ColorName {
      using Value = std::variant<CellColor, PaletteRole>;

      [[nodiscard]] static std::optional<Value> parse(std::string_view name) noexcept;

    private:
      [[nodiscard]] static bool sameRole(std::string_view left, std::string_view right) noexcept;

      [[nodiscard]] static std::optional<Value> literal(std::string_view name) noexcept;
    };

  }
}

// Interface: core/configuration.cppm
export {
  namespace telar::gui {

    // Grid fitting for terminal text; see fonts::GlyphHinting.
    enum class FontHinting : std::uint8_t {
      native,
      light,
      full,
    };

    struct FontConfiguration {
      static constexpr std::size_t name_capacity = 256;
      static constexpr float default_size = 15;
      static constexpr float minimum_size = 6;
      static constexpr float maximum_size = 96;
      static constexpr float minimum_line_height = 0.75F;
      static constexpr float maximum_line_height = 3;
      static constexpr float minimum_letter_spacing = -5;
      static constexpr float maximum_letter_spacing = 20;
      static constexpr std::uint8_t maximum_thicken_strength = 255;

      runtime::FixedText<name_capacity> family;
      runtime::FixedText<name_capacity> style;
      float size = default_size;
      float line_height = 1;
      float letter_spacing = 0;
      // Full grid fitting with half a pixel of dilation measured sharpest at a browser's weight.
      bool thicken = true;
      std::uint8_t thicken_strength = maximum_thicken_strength;
      FontHinting hinting = FontHinting::full;
    };

    struct HistoryConfiguration {
      bool show_agent_commands = false;
      bool enter_runs = false;
      bool match_fts = false;
    };

    enum class PromptMode : std::uint8_t {
      classic,
      telar,
    };

    enum class PromptMotion : std::uint8_t {
      spring,
      ease,
      none,
    };

    enum class PromptKeymap : std::uint8_t {
      emacs,
      vim,
    };

    // A key `client.prompt.bindings` binds: a KeyChord's key, character and modifiers, and the
    // index of its action; `normal` binds it in vim's normal mode instead of typing.
    struct PromptBinding {
      std::uint8_t key = 0;
      std::uint32_t character = 0;
      unsigned modifiers = 0;
      std::uint8_t action = 0;
      bool normal = false;

      bool operator==(const PromptBinding&) const = default;
    };

    // `client.prompt`: the shell prompt as the shell draws it, or telar's own command editor.
    struct PromptConfiguration {
      static constexpr std::uint8_t default_max_lines = 12;
      static constexpr std::uint8_t maximum_max_lines = 64;

      PromptMode mode = PromptMode::classic;
      PromptMotion motion = PromptMotion::spring;
      PromptKeymap keymap = PromptKeymap::emacs;
      bool ghost = true;
      std::uint8_t max_lines = default_max_lines;
      std::vector<PromptBinding> bindings;

      bool operator==(const PromptConfiguration&) const = default;
    };

    struct SoundPolicy {
      bool enabled = true;
      bool ready = true;
      bool needs_input = true;
    };

    enum class NotificationDelivery : std::uint8_t {
      telar,
      system,
    };

    // How panes scroll: by pixels, a wheel notch settling in `wheel_ms`, with `overscan` views of
    // rows asked for around the shown one while it moves; and whether the separator of the command
    // being read stays on the top row.
    struct ScrollConfiguration {
      static constexpr std::uint16_t default_wheel_ms = 80;
      static constexpr std::uint16_t maximum_wheel_ms = 400;
      static constexpr float maximum_overscan = 4;

      bool smooth = true;
      std::uint16_t wheel_ms = default_wheel_ms;
      float overscan = 1;
      bool sticky_headers = true;
    };

    struct Configuration {
      static constexpr std::size_t maximum_editor_bytes = 4096;
      static constexpr std::size_t maximum_window_title_bytes = 128;
      static constexpr std::chrono::milliseconds default_blink_interval{600};
      static constexpr std::chrono::milliseconds minimum_blink_interval{100};
      static constexpr std::chrono::milliseconds maximum_blink_interval{5000};
      static constexpr float default_sidebar_width = 240;
      static constexpr float minimum_sidebar_width = 220;
      static constexpr float maximum_sidebar_width = 800;
      static constexpr float minimum_chrome_scale = 0.5F;
      static constexpr float maximum_chrome_scale = 2;
      static constexpr float maximum_padding = 256;
      static constexpr std::uint16_t minimum_fps = 30;
      static constexpr std::uint16_t maximum_fps = 240;
      static constexpr std::uint16_t default_fps = 60;
      static constexpr std::uint8_t default_background_blur = 20;
      static constexpr std::uint8_t maximum_background_blur = 255;

      FontConfiguration font;
      runtime::FixedText<maximum_editor_bytes> editor;
      runtime::FixedText<maximum_window_title_bytes> window_title;
      HistoryConfiguration history;
      PromptConfiguration prompt;
      SoundPolicy sound;
      NotificationDelivery notification_delivery = NotificationDelivery::telar;
      Theme theme;
      ThemeSelection themes;
      CursorShape cursor = CursorShape::block;
      ScrollConfiguration scroll;
      bool cursor_blink = true;
      std::chrono::milliseconds blink_interval = default_blink_interval;
      float background_opacity = 1;
      BackgroundOpacity opacity;
      std::uint8_t background_blur = default_background_blur;
      float padding_x = 0;
      float padding_y = 0;
      float chrome_scale = 1;
      float sidebar_width = default_sidebar_width;
      // `sidebar.width = "auto"`: the window fits the sidebar to its content when it opens, on a
      // reload and on a double click of its edge.
      bool sidebar_width_auto = true;
      std::uint16_t max_fps = 0;
      bool sidebar_visible = true;
      bool pane_gaps = true;
      std::optional<bool> titlebar;
    };

  }
}

// Interface: core/geometry.cppm
export {
  namespace telar::gui {

    struct Point {
      float x = 0;
      float y = 0;

      bool operator==(const Point&) const = default;
    };

    struct Rect {
      float x = 0;
      float y = 0;
      float width = 0;
      float height = 0;

      [[nodiscard]] float right() const noexcept;

      [[nodiscard]] float bottom() const noexcept;

      [[nodiscard]] bool contains(Point point) const noexcept;

      [[nodiscard]] Rect intersect(Rect other) const noexcept;

      // Replaces each rectangle with its intersection with area, as intersect does for one. A
      // caller with many rectangles makes one call per batch, so the loop stays in this unit,
      // where it vectorizes.
      static void intersectEach(std::span<Rect> rectangles, Rect area) noexcept;

      [[nodiscard]] Rect inset(float horizontal, float vertical) const noexcept;

      [[nodiscard]] bool empty() const noexcept;

      bool operator==(const Rect&) const = default;
    };

    struct Viewport {
      static constexpr float maximum_scale = 8;

      std::uint32_t width = 0;
      std::uint32_t height = 0;
      float scale = 1;
      std::uint32_t controls = 0;

      [[nodiscard]] bool valid() const noexcept;

      bool operator==(const Viewport&) const = default;
    };

  }
}

// Interface: core/metrics.cppm
export {
  namespace telar::gui {

    struct CellMetrics {
      static constexpr float fallback_baseline = 14;

      float width = default_terminal_size.cell_width_px;
      float height = default_terminal_size.cell_height_px;
      float baseline = fallback_baseline;
      std::uint16_t pixels = static_cast<std::uint16_t>(FontConfiguration::default_size);

      bool operator==(const CellMetrics&) const = default;
    };

    struct ChromeMetrics {
      // Bar heights are specified for this terminal font size and scale with it.
      static constexpr float design_font_size = 14;
      static constexpr float maximum_text = 4096;
      static constexpr float logical_top_bar = 44;
      static constexpr float logical_status_bar = 38;
      static constexpr float logical_pane_header = 32;
      static constexpr float logical_pane_gap = 8;
      static constexpr float logical_pane_border = 1;
      static constexpr float title_ratio = 1;
      static constexpr float body_ratio = 0.93F;
      static constexpr float small_ratio = 0.855F;
      static constexpr float sans_line_ratio = 1.3F;
      static constexpr float minimum_text = 6;

      float ratio = 1;
      // The display scale times the chrome text's growth over the design font. Lengths that frame
      // chrome text (insets, marks, rows) follow it to keep their proportion to that text.
      float text_ratio = 1;
      float top_bar = logical_top_bar;
      float status_bar = logical_status_bar;
      float pane_header = logical_pane_header;
      std::uint16_t title = 14;
      std::uint16_t body = 13;
      std::uint16_t small = 12;

      static ChromeMetrics resolve(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept;

      [[nodiscard]] float px(float logical) const noexcept;

      [[nodiscard]] float textPx(float logical) const noexcept;

      [[nodiscard]] static float lineHeight(std::uint16_t pixels) noexcept;
    };

    struct WindowGeometry {
      static constexpr float sidebar_minimum = Configuration::minimum_sidebar_width;
      static constexpr float sidebar_maximum = Configuration::maximum_sidebar_width;
      static constexpr float workbench_margin = 8;
      static constexpr float workbench_minimum_columns = 20;

      Rect navigation;
      Rect sidebar;
      Rect terminal;
      Rect status;
      bool rail = false;

      static WindowGeometry measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept;

      static WindowGeometry measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells, const ChromeMetrics& chrome) noexcept;
    };

  }
}

// Interface: core/terminal_surface.cppm
export {
  namespace telar::gui {

    struct TerminalSurface {
      Rect content;
      Point cell;
      std::uint64_t attachment_generation = 0;
      float scale = 1;

      bool operator==(const TerminalSurface&) const = default;
    };

  }
}
