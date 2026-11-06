#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>

namespace telar::gui {

struct SidebarGeometry {
  static constexpr float margin = 8;
  static constexpr float header_gap = 6;
  static constexpr float workspace_vertical_padding = 20;
  static constexpr float edge_width = 1;

  Rect machines;
  Rect projects_header;
  Rect projects;
  Rect activity_header;
  Rect activity;

  [[nodiscard]] static float workspaceHeight(const ChromeMetrics &chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(workspace_vertical_padding);
  }

  [[nodiscard]] static SidebarGeometry measure(Rect area, const ChromeMetrics &chrome, std::size_t, bool machines_shown = false) noexcept {
    const auto inset = chrome.px(margin);
    Rect content{.x = area.x + inset, .y = area.y + inset, .width = std::max(0.0F, area.width - edge_width - 2 * inset), .height = std::max(0.0F, area.height - 2 * inset)};
    const auto header = ChromeMetrics::lineHeight(chrome.body);
    const auto gap = chrome.px(header_gap);
    SidebarGeometry geometry;
    if (content.width <= 0 || content.height < header) {
      return geometry;
    }

    constexpr float minimum_machine_headers = 3;
    if (machines_shown && content.height >= minimum_machine_headers * header) {
      geometry.machines = {.x = content.x, .y = content.y, .width = content.width, .height = header};
      content.y += header + gap;
      content.height -= header + gap;
    }

    geometry.activity_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
    geometry.activity = {.x = content.x, .y = content.y + header + gap, .width = content.width, .height = std::max(0.0F, content.height - header - gap)};

    return geometry;
  }
};

}
