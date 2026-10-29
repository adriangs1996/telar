#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>

namespace telar::gui {

struct HistoryHintMeasurements {
  float key = 0;
  float word = 0;
};

struct HistoryHintGeometry {
  static constexpr float padding = 6;
  static constexpr float word_gap = 6;
  static constexpr float minimum_key_width = 22;
  static constexpr float key_padding = 10;
  static constexpr float minimum_key_height = 20;
  static constexpr float key_vertical_padding = 4;
  static constexpr float corner_radius = 4;
  static constexpr float key_ring_alpha = 0.2F;
  static constexpr float key_text_alpha = 0.7F;
  static constexpr float ring_width = 1;

  Rect bounds;
  Rect keycap;
  Rect key_text;
  Rect word;

  [[nodiscard]] static float width(ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    return keyWidth(chrome, measured.key) + chrome.px(word_gap) + measured.word + chrome.px(padding * 2);
  }

  [[nodiscard]] static HistoryHintGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    HistoryHintGeometry result;
    result.bounds = bounds;
    const auto x = bounds.x + chrome.px(padding);
    const auto key_width = std::min(keyWidth(chrome, measured.key), std::max(0.0F, bounds.right() - x));
    const auto height = std::min(bounds.height, std::max(chrome.px(minimum_key_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(key_vertical_padding)));
    result.keycap = {.x = x, .y = bounds.y + ((bounds.height - height) / 2), .width = key_width, .height = height};
    const auto text_width = std::min(measured.key, key_width);
    result.key_text = {.x = x + ((key_width - text_width) / 2), .y = result.keycap.y, .width = text_width, .height = height};
    const auto word_x = x + key_width + chrome.px(word_gap);
    result.word = {.x = word_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - word_x), .height = bounds.height};

    return result;
  }

private:
  [[nodiscard]] static float keyWidth(ChromeMetrics chrome, float measured) noexcept {
    return std::max(chrome.px(minimum_key_width), measured + chrome.px(key_padding));
  }
};

}
