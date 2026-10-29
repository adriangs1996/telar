#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/history_footer.hpp"
#include "presentation/history_hint_geometry.hpp"
#include <algorithm>
#include <array>
#include <cstddef>

namespace telar::gui {

struct HistoryFooterMeasurements {
  std::array<HistoryHintMeasurements, HistoryFooter::capacity> hints{};
  std::size_t count = 0;
  float range = 0;
  bool empty = true;
  bool error = false;
};

struct HistoryFooterGeometry {
  static constexpr float horizontal_inset = 16;
  static constexpr float vertical_inset = 5;
  static constexpr float hint_gap = 4;
  static constexpr float range_gap = 12;
  static constexpr float separator_height = 1;

  std::array<HistoryHintGeometry, HistoryFooter::capacity> hints{};
  std::size_t count = 0;
  Rect separator;
  Rect range;
  Rect error;
  bool range_visible = false;
  bool error_visible = false;

  [[nodiscard]] static HistoryFooterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFooterMeasurements &measured) noexcept {
    HistoryFooterGeometry result;
    if (area.empty()) {
      return result;
    }

    result.separator = {.x = area.x, .y = area.y, .width = area.width, .height = separator_height};
    const auto left = area.x + chrome.px(horizontal_inset);
    const auto limit = area.right() - chrome.px(horizontal_inset);
    if (measured.error) {
      result.error = {.x = left, .y = area.y, .width = std::max(0.0F, limit - left), .height = area.height};
      result.error_visible = true;

      return result;
    }

    auto x = left - chrome.px(HistoryHintGeometry::padding);
    const auto available = std::min(measured.count, measured.hints.size());
    for (std::size_t index = 0; index < available; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.hints[index]);
      if (x + width > limit) {
        break;
      }

      const Rect bounds{.x = x, .y = area.y + chrome.px(vertical_inset), .width = width, .height = std::max(0.0F, area.height - chrome.px(vertical_inset * 2))};
      result.hints[index] = HistoryHintGeometry::derive(bounds, chrome, measured.hints[index]);
      ++result.count;
      x += width + chrome.px(hint_gap);
    }

    if (!measured.empty && x + chrome.px(range_gap) + measured.range <= limit) {
      result.range = {.x = limit - measured.range, .y = area.y, .width = measured.range, .height = area.height};
      result.range_visible = true;
    }

    return result;
  }
};

}
