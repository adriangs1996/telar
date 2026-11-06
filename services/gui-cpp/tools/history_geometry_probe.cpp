#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <initializer_list>
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.presentation.history_inspection_geometry;
import telar.gui.core.metrics;

namespace {

void frame() {
  using namespace telar::gui;
  const auto viewport = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  chrome.body = probe::read<std::uint16_t>();
  chrome.small = probe::read<std::uint16_t>();
  chrome.status_bar = static_cast<float>(probe::read<std::uint32_t>());
  const auto cell_height = probe::read<std::uint32_t>();
  const auto inspecting = probe::read<std::uint8_t>() != 0;
  const auto offset = probe::read<float>();
  auto geometry = HistoryModalGeometry::measure({.viewport = viewport, .chrome = chrome, .cell_height = static_cast<float>(cell_height)}, inspecting);
  geometry.offsetY(offset);
  for (const auto area : {geometry.viewport, geometry.bounds, geometry.header, geometry.results, geometry.inspection, geometry.search, geometry.footer, geometry.inspectionContent(chrome), geometry.inspectionActions(chrome)}) {
    probe::writeRect(area);
  }

  probe::write(geometry.row_height);
  probe::write(geometry.group_height);
  probe::write(static_cast<std::uint8_t>(geometry.compact));
}

}

int main() {
  try {
    while (true) {
      const auto operation = std::getchar();
      if (operation == EOF) {
        return 0;
      }

      if (operation != 0) {
        return 1;
      }

      frame();
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
