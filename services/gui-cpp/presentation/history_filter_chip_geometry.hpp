#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>

namespace telar::gui {

struct HistoryFilterChipMeasurements {
  float label = 0;
  float value = 0;
  bool has_value = false;
};

struct HistoryFilterChipGeometry {
  static constexpr float horizontal_padding = 10;
  static constexpr float value_gap = 6;
  static constexpr float corner_radius = 4;
  static constexpr float ring_width = 1;
  static constexpr float danger_ring_alpha = 0.8F;

  Rect bounds;
  Rect label;
  Rect value;

  [[nodiscard]] static float width(ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    auto result = measured.label + chrome.px(horizontal_padding * 2);
    if (measured.has_value) {
      result += measured.value + chrome.px(value_gap);
    }

    return result;
  }

  [[nodiscard]] static HistoryFilterChipGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    HistoryFilterChipGeometry result;
    result.bounds = bounds;
    result.label = {.x = bounds.x + chrome.px(horizontal_padding), .y = bounds.y, .width = std::max(0.0F, bounds.width - chrome.px(horizontal_padding * 2)), .height = bounds.height};
    const auto painted = result.label.empty() ? 0.0F : std::min(measured.label, result.label.width);
    const auto value_x = result.label.x + (painted + chrome.px(value_gap));
    result.value = {.x = value_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - chrome.px(horizontal_padding) - value_x), .height = bounds.height};

    return result;
  }
};

}
