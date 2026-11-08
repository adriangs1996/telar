#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_geometry;
import telar.gui.tools.probe_io;
import telar.gui.core.metrics;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.suggestion_geometry;

namespace {

using namespace telar::gui;

void frame() {
  Configuration configuration;
  configuration.font.size = probe::read<float>();
  configuration.chrome_scale = probe::read<float>();
  const auto density = probe::read<float>();
  const auto area = probe::readRect();
  const auto count = probe::read<std::uint16_t>();
  const auto machines = probe::read<std::uint8_t>() != 0;
  constexpr std::uint32_t viewport_extent = 4096;
  const auto chrome = ChromeMetrics::resolve(configuration, {.width = viewport_extent, .height = viewport_extent, .scale = density}, {});
  const auto regions = SidebarGeometry::measure(area, chrome, count, machines);
  const auto card = AgentCardGeometry::derive(chrome);
  probe::write(chrome.ratio);
  probe::write(chrome.title);
  probe::write(chrome.body);
  probe::write(chrome.small);
  probe::write(SidebarGeometry::workspaceHeight(chrome));
  for (const auto bounds : {regions.machines, regions.projects_header, regions.projects, regions.activity_header, regions.activity}) {
    probe::writeRect(bounds);
  }

  for (const auto value : {card.small_row, card.title_row, card.scale, card.height(), card.compactHeight(), card.height() + card.px(AgentCardGeometry::spacing), card.cardWidth(area.width)}) {
    probe::write(value);
  }

  constexpr std::array lengths{AgentCardGeometry::horizontal_padding, AgentCardGeometry::vertical_padding, AgentCardGeometry::spacing, AgentCardGeometry::radius, AgentCardGeometry::gap, AgentCardGeometry::mark_side, AgentCardGeometry::compact_vertical_padding, AgentCardGeometry::task_indent, AgentCardGeometry::group_gap};
  for (const auto length : lengths) {
    probe::write(card.px(length));
  }

  for (const auto role : {AgentCardGeometry::Row::context, AgentCardGeometry::Row::title, AgentCardGeometry::Row::detail}) {
    probe::writeRect(card.row(area, role));
  }
}

}

int main() try {
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    if (operation != 0) {
      throw std::invalid_argument{"UnknownSidebarGeometryOperation"};
    }

    frame();
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
