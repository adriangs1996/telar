module telar.gui.foundation.drawing;

import std;

import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline drawing {

  float HistoryHintGeometry::width(ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    return keyWidth(chrome, measured.key) + chrome.px(word_gap) + measured.word + chrome.px(padding * 2);
  }

  HistoryHintGeometry HistoryHintGeometry::derive(Rect bounds, ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    HistoryHintGeometry result;

    result.bounds = bounds;
    const auto x = bounds.x + chrome.px(padding);
    const auto key_width = std::min(keyWidth(chrome, measured.key), std::max(0.0F, bounds.right() - x));
    const auto height = keyHeight(chrome, bounds.height);

    result.keycap = {.x = x, .y = bounds.y + ((bounds.height - height) / 2), .width = key_width, .height = height};
    const auto text_width = std::min(measured.key, key_width);

    result.key_text = {.x = x + ((key_width - text_width) / 2), .y = result.keycap.y, .width = text_width, .height = height};
    const auto word_x = x + key_width + chrome.px(word_gap);

    result.word = {.x = word_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - word_x), .height = bounds.height};

    return result;
  }

  float HistoryHintGeometry::keyHeight(ChromeMetrics chrome, float available) noexcept {
    return std::min(available, std::max(chrome.px(minimum_key_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(key_vertical_padding)));
  }

  float HistoryHintGeometry::keyWidth(ChromeMetrics chrome, float measured) noexcept {
    return std::max(chrome.px(minimum_key_width), measured + chrome.px(key_padding));
  }

}
