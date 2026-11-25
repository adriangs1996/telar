module telar.gui.application;

import std;
import telar.gui.foundation.core;

namespace telar::gui::application {

  std::uint16_t SidebarColumns::clamp(std::uint16_t host_width, std::int64_t requested_width) {
    if (requested_width <= 0 || std::cmp_greater(requested_width, std::numeric_limits<std::uint16_t>::max())) {
      throw std::invalid_argument{"InvalidWidth"};
    }

    if (host_width < minimum_width + minimum_workbench) {
      return minimum_width;
    }

    return std::clamp(static_cast<std::uint16_t>(requested_width), minimum_width, static_cast<std::uint16_t>(host_width - minimum_workbench));
  }

  float SidebarGeometry::sectionGap(const ChromeMetrics& chrome) noexcept {
    return std::round(chrome.textPx(section_gap));
  }

  float SidebarGeometry::workspaceHeight(const ChromeMetrics& chrome) noexcept {
    return ChromeMetrics::lineHeight(chrome.body) + ChromeMetrics::lineHeight(chrome.small) + chrome.px(workspace_vertical_padding);
  }

  SidebarGeometry SidebarGeometry::measure(Rect area, const ChromeMetrics& chrome, std::size_t /*unused*/) noexcept {
    const auto inset = std::round(chrome.textPx(margin));
    const Rect content{.x = area.x + inset, .y = area.y + inset, .width = std::max(0.0F, area.width - 2 * inset), .height = std::max(0.0F, area.height - 2 * inset)};
    const auto header = chrome.pane_header;
    const auto gap = 0.0F;
    SidebarGeometry geometry;

    if (content.width <= 0 || content.height < header) {
      return geometry;
    }

    geometry.activity_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
    geometry.activity = {.x = content.x, .y = content.y + header + gap, .width = content.width, .height = std::max(0.0F, content.height - header - gap)};

    return geometry;
  }

}
