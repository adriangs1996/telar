module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.presentation.suggestion_geometry;

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

  SidebarGeometry SidebarGeometry::measure(Rect area, const ChromeMetrics& chrome, std::size_t, SidebarMachines machines) noexcept {
    const auto inset = std::round(chrome.textPx(margin));
    Rect content{.x = area.x + inset, .y = area.y + inset, .width = std::max(0.0F, area.width - 2 * inset), .height = std::max(0.0F, area.height - 2 * inset)};
    const auto header = chrome.pane_header;
    const auto gap = 0.0F;
    SidebarGeometry geometry;

    if (content.width <= 0 || content.height < header) {
      return geometry;
    }

    constexpr float minimum_machine_headers = 3;
    if (machines.shown && content.height >= minimum_machine_headers * header) {
      geometry.machines_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
      content.y += header;
      content.height -= header;
      // Activity keeps two headers of room; machine rows that do not fit stay out whole.
      const auto row = MachineChromeGeometry::listRowHeight(chrome);
      const auto section = sectionGap(chrome);
      const auto room = std::max(0.0F, content.height - ((minimum_machine_headers - 1) * header) - section);
      const auto rows = std::min(static_cast<float>(machines.rows), std::floor(room / row));

      geometry.machines = {.x = content.x, .y = content.y, .width = content.width, .height = rows * row};
      content.y += geometry.machines.height + section;
      content.height -= geometry.machines.height + section;
    }

    geometry.activity_header = {.x = content.x, .y = content.y, .width = content.width, .height = header};
    geometry.activity = {.x = content.x, .y = content.y + header + gap, .width = content.width, .height = std::max(0.0F, content.height - header - gap)};

    return geometry;
  }

}
