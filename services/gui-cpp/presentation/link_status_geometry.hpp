#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>

namespace telar::gui {

struct LinkStatusGeometry {
  static constexpr float dim_alpha = 0.6F;
  static constexpr float line_height_factor = 1.5F;
  static constexpr float line_gap = 6;
  static constexpr float inset = 24;

  Rect bounds;
  Rect headline;
  Rect detail;

  [[nodiscard]] static LinkStatusGeometry measure(Rect area, const ChromeMetrics &chrome, bool has_detail) noexcept {
    if (area.width <= 0 || area.height <= 0) {
      return {};
    }

    const auto height = static_cast<float>(chrome.title) * line_height_factor;
    const auto lines = has_detail ? 2.0F : 1.0F;
    const auto gap = chrome.px(line_gap);
    const auto block_height = (lines * height) + ((lines - 1) * gap);
    const Rect headline{.x = area.x + chrome.px(inset), .y = area.y + std::max(0.0F, (area.height - block_height) / 2), .width = std::max(0.0F, area.width - 2 * chrome.px(inset)), .height = height};
    auto detail = headline;
    detail.y += height + gap;

    return {.bounds = area, .headline = headline, .detail = detail};
  }
};

}
