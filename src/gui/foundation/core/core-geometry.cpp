module telar.gui.foundation.core;

import std;

namespace telar::gui::inline foundation::inline core {

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

  std::uint32_t CellRectangle::right() const noexcept {
    return static_cast<std::uint32_t>(x) + width;
  }

  std::uint32_t CellRectangle::bottom() const noexcept {
    return static_cast<std::uint32_t>(y) + height;
  }

  bool CellRectangle::empty() const noexcept {
    return width == 0 || height == 0;
  }

  CellRectangle CellRectangle::inner(std::uint16_t margin) const noexcept {
    const auto shrink = static_cast<std::uint32_t>(margin) * 2;
    if (width <= shrink || height <= shrink) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();

    return {
        .x = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(x) + margin, static_cast<std::uint32_t>(maximum))),
        .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + margin, static_cast<std::uint32_t>(maximum))),
        .width = static_cast<std::uint16_t>(width - shrink),
        .height = static_cast<std::uint16_t>(height - shrink),
    };
  }

  CellRectangle CellRectangle::intersect(CellRectangle other) const noexcept {
    const auto left = std::max(x, other.x);
    const auto top = std::max(y, other.y);
    const auto end = std::max<std::uint32_t>(left, std::min(right(), other.right()));
    const auto lower = std::max<std::uint32_t>(top, std::min(bottom(), other.bottom()));

    return {.x = left, .y = top, .width = static_cast<std::uint16_t>(end - left), .height = static_cast<std::uint16_t>(lower - top)};
  }

  CellRectangle CellRectangle::row(std::uint16_t index) const noexcept {
    if (index >= height) {
      return {.x = x, .y = y};
    }

    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();

    return {.x = x, .y = static_cast<std::uint16_t>(std::min(static_cast<std::uint32_t>(y) + index, static_cast<std::uint32_t>(maximum))), .width = width, .height = 1};
  }

}
