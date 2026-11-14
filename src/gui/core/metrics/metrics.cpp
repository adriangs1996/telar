module telar.gui.core.metrics;

import std;

import telar.base.text;

namespace telar::gui {

  float BackgroundOpacity::resolve(Surface surface, float fallback) const noexcept {
    return overrides[static_cast<std::size_t>(surface)].value_or(fallback);
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

    return syntax_styles[index].value_or(SyntaxStyleValues{.color = color(defaults[index])});
  }

  ThemeValues ThemeSelection::resolve(Appearance appearance, const std::optional<ThemeValues>& locked) const noexcept {
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

  std::optional<ColorName::Value> ColorName::parse(std::string_view name) noexcept {
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

  std::optional<ColorName::Value> ColorName::literal(std::string_view name) noexcept {
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

  float Rect::right() const noexcept {
    return x + width;
  }

  float Rect::bottom() const noexcept {
    return y + height;
  }

  bool Rect::contains(Point point) const noexcept {
    return point.x >= x && point.y >= y && point.x < right() && point.y < bottom();
  }

  Rect Rect::intersect(Rect other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);

    return {.x = left, .y = top, .width = std::max(0.0F, std::min(right(), other.right()) - left), .height = std::max(0.0F, std::min(bottom(), other.bottom()) - top)};
  }

  void Rect::intersectEach(std::span<Rect> rectangles, Rect area) noexcept {
    for (auto& rectangle : rectangles) {
      rectangle = rectangle.intersect(area);
    }
  }

  Rect Rect::inset(float horizontal, float vertical) const noexcept {
    return {.x = x + horizontal, .y = y + vertical, .width = std::max(0.0F, width - horizontal * 2), .height = std::max(0.0F, height - vertical * 2)};
  }

  bool Rect::empty() const noexcept {
    return width <= 0 || height <= 0;
  }

  bool Viewport::valid() const noexcept {
    return width != 0 && height != 0 && std::isfinite(scale) && scale > 0 && scale <= maximum_scale;
  }

  ChromeMetrics ChromeMetrics::resolve(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept {
    ChromeMetrics metrics;

    metrics.ratio = viewport.scale;
    const auto base = configuration.font.size * viewport.scale * configuration.chrome_scale;
    const auto bars = base / design_font_size;

    metrics.text_ratio = bars;

    metrics.top_bar = std::round(logical_top_bar * bars);
    metrics.status_bar = std::round(logical_status_bar * bars);
    metrics.pane_header = std::round(logical_pane_header * bars);

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

  float ChromeMetrics::px(float logical) const noexcept {
    return logical * ratio;
  }

  float ChromeMetrics::textPx(float logical) const noexcept {
    return logical * text_ratio;
  }

  float ChromeMetrics::lineHeight(std::uint16_t pixels) noexcept {
    return std::ceil(static_cast<float>(pixels) * sans_line_ratio);
  }

  WindowGeometry WindowGeometry::measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells) noexcept {
    const auto chrome = ChromeMetrics::resolve(configuration, viewport, cells);

    return measure(configuration, viewport, cells, chrome);
  }

  WindowGeometry WindowGeometry::measure(const Configuration& configuration, const Viewport& viewport, const CellMetrics& cells, const ChromeMetrics& chrome) noexcept {
    const auto width = static_cast<float>(viewport.width);
    const auto height = static_cast<float>(viewport.height);
    const auto padding_x = std::round(configuration.padding_x * viewport.scale);
    const auto padding_y = std::round(configuration.padding_y * viewport.scale);
    const auto margin = std::max(padding_x, std::round(workbench_margin * viewport.scale));
    const auto minimum = std::round(sidebar_minimum * viewport.scale);
    const auto room = std::max(0.0F, width - (2 * margin) - (workbench_minimum_columns * cells.width));
    const auto maximum = std::max(minimum, std::min(std::round(sidebar_maximum * viewport.scale), room));

    WindowGeometry geometry;

    geometry.navigation = {.x = 0, .y = 0, .width = width, .height = chrome.top_bar};
    geometry.rail = !configuration.sidebar_visible || room < minimum;

    auto requested = std::clamp(std::round(configuration.sidebar_width * viewport.scale), minimum, maximum);

    if (geometry.rail) {
      requested = 0;
    }

    const auto left = requested > 0 ? requested : margin;

    geometry.sidebar = {.x = 0, .y = chrome.top_bar, .width = requested, .height = std::max(0.0F, height - chrome.top_bar)};
    geometry.status = {.x = left, .y = height - chrome.status_bar, .width = std::max(0.0F, width - left), .height = chrome.status_bar};
    geometry.terminal = {.x = left, .y = chrome.top_bar + padding_y, .width = std::max(0.0F, width - left - margin), .height = std::max(0.0F, height - chrome.top_bar - chrome.status_bar - padding_y * 2)};

    return geometry;
  }

}
