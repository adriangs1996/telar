module;

#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>


#include "telar_client/serializers/telar_cells.hpp"
#include <cstdint>


#include <variant>


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>


#include <cmath>


#include "terminal_size.hpp"

export module telar.gui.core.metrics;

export import telar.base.text;

// Interface: core/background_opacity.cppm
export {
namespace telar::gui {

  struct BackgroundOpacity {
    enum class Surface : std::size_t {
      sidebar,
      topbar,
      bottombar,
      workspace,
      pane
    };
    static constexpr std::array<const char *, 5> names{"sidebar", "topbar", "bottombar", "workspace", "pane"};
    std::array<std::optional<float>, names.size()> overrides{};

    [[nodiscard]] inline float resolve(Surface surface, float fallback) const noexcept {
      return overrides[static_cast<std::size_t>(surface)].value_or(fallback);
    }

    [[nodiscard]] inline float minimum(float fallback) const noexcept {
      auto result = 1.0F;
      for (const auto value : overrides) {
        result = std::min(result, value.value_or(fallback));
      }
      return result;
    }
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

  bool operator==(const TerminalThemeValues &) const = default;
};

struct SyntaxStyleValues {
  CellColor color;
  bool italic = false;
  bool bold = false;

  bool operator==(const SyntaxStyleValues &) const = default;
};

struct ThemeValues {
  ThemeName base = ThemeName::terminal;
  std::array<CellColor, palette_names.size()> palette{};
  TerminalThemeValues terminal;
  std::array<std::optional<SyntaxStyleValues>, syntax_names.size()> syntax_styles{};

  [[nodiscard]] inline CellColor color(PaletteRole role) const noexcept {
    return palette[static_cast<std::size_t>(role)];
  }

  [[nodiscard]] inline SyntaxStyleValues syntaxStyle(SyntaxRole role) const noexcept {
    const auto index = static_cast<std::size_t>(role);
    constexpr std::array defaults{PaletteRole::text, PaletteRole::mauve, PaletteRole::green, PaletteRole::peach, PaletteRole::subtext0, PaletteRole::peach, PaletteRole::peach, PaletteRole::teal, PaletteRole::blue, PaletteRole::yellow, PaletteRole::text, PaletteRole::text, PaletteRole::mauve, PaletteRole::subtext0, PaletteRole::subtext0};

    return syntax_styles[index].value_or(SyntaxStyleValues{.color = color(defaults[index])});
  }

  bool operator==(const ThemeValues &) const = default;
};

struct ThemeSelection {
  ThemeValues base;
  std::optional<ThemeValues> light;
  std::optional<ThemeValues> dark;

  [[nodiscard]] inline ThemeValues resolve(Appearance appearance, const std::optional<ThemeValues> &locked = {}) const noexcept {
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

  [[nodiscard]] inline Color chromeColor(PaletteRole role) const noexcept {
    const bool background_role = role == PaletteRole::panel_bg || role == PaletteRole::surface0 || role == PaletteRole::surface1 || role == PaletteRole::surface_dim;

    return resolve(chrome[static_cast<std::size_t>(role)], background_role ? background : foreground);
  }

  bool operator==(const Theme &) const = default;

  [[nodiscard]] inline Color resolve(const CellColor &color, Color fallback) const noexcept {
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
}

// Interface: core/color_name.cppm
export {
namespace telar::gui {

struct ColorName {
  using Value = std::variant<CellColor, PaletteRole>;

  [[nodiscard]] inline static std::optional<Value> parse(std::string_view name) noexcept {
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

private:
  [[nodiscard]] inline static bool sameRole(std::string_view left, std::string_view right) noexcept {
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

  [[nodiscard]] inline static std::optional<Value> literal(std::string_view name) noexcept {
    constexpr std::string_view pattern = "#RRGGBB";
    constexpr std::string_view digits = "0123456789abcdef";
    if (name.size() != pattern.size() || name.front() != '#') {
      return std::nullopt;
    }

    name.remove_prefix(1);
    const bool negative = name.front() == '-';
    if (negative || name.front() == '+') {
      name.remove_prefix(1);
    }

    if (name.front() == '_' || name.back() == '_') {
      return std::nullopt;
    }

    std::uint32_t value = 0;
    for (const auto byte : name) {
      if (byte == '_') {
        continue;
      }

      const auto digit = digits.find(runtime::asciiLower(byte));
      if (digit == std::string_view::npos || (negative && digit != 0)) {
        return std::nullopt;
      }

      value = (value * static_cast<std::uint32_t>(digits.size())) + static_cast<std::uint32_t>(digit);
    }

    constexpr unsigned channel_bits = 8;

    return CellColor{.kind = CellColor::Kind::rgb, .channels = {static_cast<Byte>(value >> (channel_bits * 2)), static_cast<Byte>(value >> channel_bits), static_cast<Byte>(value)}};
  }
};

}
}

// Interface: core/configuration.cppm
export {
namespace telar::gui {

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
  bool thicken = false;
  std::uint8_t thicken_strength = maximum_thicken_strength;
};

struct HistoryConfiguration {
  bool show_agent_commands = false;
  bool enter_runs = false;
  bool match_fts = false;
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

struct Configuration {
  static constexpr std::size_t maximum_editor_bytes = 4096;
  static constexpr std::size_t maximum_window_title_bytes = 128;
  static constexpr std::chrono::milliseconds default_blink_interval{600};
  static constexpr std::chrono::milliseconds minimum_blink_interval{100};
  static constexpr std::chrono::milliseconds maximum_blink_interval{5000};
  static constexpr float default_sidebar_width = 284;
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
  SoundPolicy sound;
  NotificationDelivery notification_delivery = NotificationDelivery::telar;
  Theme theme;
  ThemeSelection themes;
  CursorShape cursor = CursorShape::block;
  bool cursor_blink = true;
  std::chrono::milliseconds blink_interval = default_blink_interval;
  float background_opacity = 1;
  BackgroundOpacity opacity;
  std::uint8_t background_blur = 0;
  float padding_x = 0;
  float padding_y = 0;
  float chrome_scale = 1;
  float sidebar_width = default_sidebar_width;
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

  bool operator==(const Point &) const = default;
};

struct Rect {
  float x = 0;
  float y = 0;
  float width = 0;
  float height = 0;

  [[nodiscard]] inline float right() const noexcept {
    return x + width;
  }

  [[nodiscard]] inline float bottom() const noexcept {
    return y + height;
  }

  [[nodiscard]] inline bool contains(Point point) const noexcept {
    return point.x >= x && point.y >= y && point.x < right() && point.y < bottom();
  }

  [[nodiscard]] inline Rect intersect(Rect other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);

    return {.x = left, .y = top, .width = std::max(0.0F, std::min(right(), other.right()) - left), .height = std::max(0.0F, std::min(bottom(), other.bottom()) - top)};
  }

  [[nodiscard]] inline Rect inset(float horizontal, float vertical) const noexcept {
    return {.x = x + horizontal, .y = y + vertical, .width = std::max(0.0F, width - horizontal * 2), .height = std::max(0.0F, height - vertical * 2)};
  }

  [[nodiscard]] inline bool empty() const noexcept {
    return width <= 0 || height <= 0;
  }

  bool operator==(const Rect &) const = default;
};

struct Viewport {
  static constexpr float maximum_scale = 8;

  std::uint32_t width = 0;
  std::uint32_t height = 0;
  float scale = 1;
  std::uint32_t controls = 0;

  [[nodiscard]] inline bool valid() const noexcept {
    return width != 0 && height != 0 && std::isfinite(scale) && scale > 0 && scale <= maximum_scale;
  }

  bool operator==(const Viewport &) const = default;
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

  bool operator==(const CellMetrics &) const = default;
};

struct ChromeMetrics {
  static constexpr float reference_font_size = FontConfiguration::default_size;
  static constexpr float maximum_text = 4096;
  static constexpr float logical_top_bar = 42;
  static constexpr float logical_status_bar = 26;
  static constexpr float logical_pane_header = 32;
  static constexpr float logical_pane_gap = 8;
  static constexpr float logical_pane_border = 1;
  static constexpr float title_ratio = 0.87F;
  static constexpr float body_ratio = 0.87F;
  static constexpr float small_ratio = 0.73F;
  static constexpr float sans_line_ratio = 1.3F;
  static constexpr float minimum_text = 6;

  float ratio = 1;
  float top_bar = logical_top_bar;
  float status_bar = logical_status_bar;
  float pane_header = logical_pane_header;
  std::uint16_t title = 13;
  std::uint16_t body = 13;
  std::uint16_t small = 11;

  inline static ChromeMetrics resolve(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells) noexcept {
    ChromeMetrics metrics;
    metrics.ratio = viewport.scale;
    metrics.top_bar = std::round(logical_top_bar * metrics.ratio);
    metrics.status_bar = std::round(logical_status_bar * metrics.ratio);
    metrics.pane_header = std::round(logical_pane_header * metrics.ratio);

    const auto base = reference_font_size * viewport.scale * configuration.chrome_scale;
    const auto text_size = [](float value) {
      return static_cast<std::uint16_t>(std::clamp(std::round(value), minimum_text, maximum_text));
    };

    metrics.title = text_size(base * title_ratio);
    metrics.body = std::min(text_size(base * body_ratio), text_size(std::floor(metrics.pane_header / sans_line_ratio)));
    metrics.small = text_size(base * small_ratio);

    const auto height = static_cast<float>(viewport.height);
    if (height < metrics.top_bar + metrics.status_bar + cells.height) {
      metrics.top_bar = 0;
    }

    if (height < metrics.status_bar + cells.height) {
      metrics.status_bar = 0;
    }

    return metrics;
  }

  [[nodiscard]] inline float px(float logical) const noexcept {
    return logical * ratio;
  }

  [[nodiscard]] inline static float lineHeight(std::uint16_t pixels) noexcept {
    return std::ceil(static_cast<float>(pixels) * sans_line_ratio);
  }
};

struct WindowGeometry {
  static constexpr float sidebar_minimum = Configuration::minimum_sidebar_width;
  static constexpr float sidebar_maximum = Configuration::maximum_sidebar_width;
  static constexpr float sidebar_gap = 8;
  static constexpr float workbench_minimum_columns = 20;

  Rect navigation;
  Rect sidebar;
  Rect terminal;
  Rect status;
  bool rail = false;

  inline static WindowGeometry measure(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells) noexcept {
    const auto chrome = ChromeMetrics::resolve(configuration, viewport, cells);

    return measure(configuration, viewport, cells, chrome);
  }

  inline static WindowGeometry measure(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells, const ChromeMetrics &chrome) noexcept {
    const auto width = static_cast<float>(viewport.width);
    const auto height = static_cast<float>(viewport.height);
    const auto padding_x = std::round(configuration.padding_x * viewport.scale);
    const auto padding_y = std::round(configuration.padding_y * viewport.scale);
    const auto gap = std::round(sidebar_gap * viewport.scale);
    const auto minimum = std::round(sidebar_minimum * viewport.scale);
    const auto room = std::max(0.0F, width - padding_x - gap - (workbench_minimum_columns * cells.width));
    const auto maximum = std::max(minimum, std::min(std::round(sidebar_maximum * viewport.scale), room));

    WindowGeometry geometry;
    geometry.navigation = {.x = 0, .y = 0, .width = width, .height = chrome.top_bar};
    geometry.status = {.x = 0, .y = height - chrome.status_bar, .width = width, .height = chrome.status_bar};
    geometry.rail = !configuration.sidebar_visible || room < minimum;

    auto requested = std::clamp(std::round(configuration.sidebar_width * viewport.scale), minimum, maximum);
    if (geometry.rail) {
      requested = 0;
    }
    const auto left = requested > 0 ? requested + gap : padding_x;
    geometry.sidebar = {.x = 0, .y = chrome.top_bar, .width = requested, .height = std::max(0.0F, height - chrome.top_bar - chrome.status_bar)};
    geometry.terminal = {.x = left, .y = chrome.top_bar + padding_y, .width = std::max(0.0F, width - left - padding_x), .height = std::max(0.0F, height - chrome.top_bar - chrome.status_bar - padding_y * 2)};

    return geometry;
  }
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

  bool operator==(const TerminalSurface &) const = default;
};

}
}
