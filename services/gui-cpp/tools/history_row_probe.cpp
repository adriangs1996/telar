#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.core.metrics;
import telar.gui.presentation.history_meta_geometry;

namespace {

enum class Flag : std::uint8_t {
  agent = 1,
  show_cwd = 2,
  has_cwd = 4,
  has_time = 8,
  expanded = 16,
};

void frame() {
  using namespace telar::gui;
  const auto bounds = probe::readRect();
  ChromeMetrics chrome;
  chrome.ratio = probe::read<float>();
  const auto row_height = probe::read<float>();
  HistoryRowMeasurements measured;
  measured.command = probe::read<float>();
  measured.cwd = probe::read<float>();
  measured.time = probe::read<float>();
  const auto flags = probe::read<std::uint8_t>();
  const auto enabled = [flags](Flag flag) {
    return (flags & static_cast<std::uint8_t>(flag)) != 0;
  };
  measured.agent = enabled(Flag::agent);
  measured.show_cwd = enabled(Flag::show_cwd);
  measured.has_cwd = enabled(Flag::has_cwd);
  measured.has_time = enabled(Flag::has_time);
  measured.expanded = enabled(Flag::expanded);
  const auto geometry = HistoryRowGeometry::derive(bounds, chrome, row_height, measured);
  for (const auto area : {geometry.frame, geometry.status, geometry.command, geometry.provider, geometry.cwd, geometry.time}) {
    probe::writeRect(area);
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
      return 1;
    }

    frame();
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
