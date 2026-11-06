#pragma once

#include "configuration.hpp"
#include "geometry.hpp"
#include "terminal_size.hpp"

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

  static ChromeMetrics resolve(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells) noexcept {
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

  [[nodiscard]] float px(float logical) const noexcept {
    return logical * ratio;
  }

  [[nodiscard]] static float lineHeight(std::uint16_t pixels) noexcept {
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

  static WindowGeometry measure(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells) noexcept {
    const auto chrome = ChromeMetrics::resolve(configuration, viewport, cells);

    return measure(configuration, viewport, cells, chrome);
  }

  static WindowGeometry measure(const Configuration &configuration, const Viewport &viewport, const CellMetrics &cells, const ChromeMetrics &chrome) noexcept {
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
