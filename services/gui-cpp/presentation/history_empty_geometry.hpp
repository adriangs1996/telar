#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/history_empty.hpp"
#include <algorithm>

namespace telar::gui {

struct HistoryEmptyMeasurements {
  float title = 0;
  float subtitle = 0;
  float import = 0;
  HistoryEmpty::Action action = HistoryEmpty::Action::none;
};

struct HistoryEmptyGeometry {
  static constexpr float title_gap = 6;
  static constexpr float action_gap = 14;
  static constexpr float action_height = 28;
  static constexpr float side_inset = 16;
  static constexpr float import_inset = 10;
  static constexpr float import_radius = 4;
  static constexpr float search_width = 180;

  Rect title;
  Rect subtitle;
  Rect action;

  [[nodiscard]] static HistoryEmptyGeometry derive(Rect area, ChromeMetrics chrome, HistoryEmptyMeasurements measured) noexcept {
    if (area.empty()) {
      return {};
    }

    const auto title_height = ChromeMetrics::lineHeight(chrome.body);
    const auto small_height = ChromeMetrics::lineHeight(chrome.small);
    const auto stack = title_height + chrome.px(title_gap) + small_height + chrome.px(action_gap) + chrome.px(action_height);
    const auto top = area.y + std::max(0.0F, (area.height - stack) / 2);
    const Rect inner{.x = area.x + chrome.px(side_inset), .y = top, .width = std::max(0.0F, area.width - chrome.px(side_inset * 2)), .height = title_height};
    const auto action_width = std::min(inner.width, measured.action == HistoryEmpty::Action::import ? measured.import + chrome.px(import_inset * 2) : chrome.px(search_width));
    const Rect subtitle{.x = inner.x, .y = inner.y + title_height + chrome.px(title_gap), .width = inner.width, .height = small_height};

    return {.title = centered(inner, measured.title), .subtitle = centered(subtitle, measured.subtitle), .action = {.x = inner.x + std::max(0.0F, (inner.width - action_width) / 2), .y = subtitle.y + small_height + chrome.px(action_gap), .width = action_width, .height = chrome.px(action_height)}};
  }

private:
  [[nodiscard]] static Rect centered(Rect area, float advance) noexcept {
    const auto width = std::min(area.width, advance);

    return {.x = area.x + std::max(0.0F, (area.width - width) / 2), .y = area.y, .width = width, .height = area.height};
  }
};

}
