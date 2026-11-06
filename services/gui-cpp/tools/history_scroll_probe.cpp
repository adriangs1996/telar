#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include "../input/wheel_accumulator.hpp"
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>

#include "input/wheel_accumulator.hpp"


import telar.gui.core.metrics;
import telar.gui.input.child_mouse;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  scroll,
  pointer_up,
  pointer_down,
};

void record(HistoryScroll &scroll, Operation operation) {
  const HistoryScrollState state{.generation = probe::read<std::uint64_t>(), .revision = probe::read<std::uint64_t>(), .ready = probe::read<std::uint8_t>() != 0, .inspecting = probe::read<std::uint8_t>() != 0};
  HistoryScrollSurface surface;
  surface.bounds = {.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()};
  surface.generation = probe::read<std::uint64_t>();
  surface.revision = probe::read<std::uint64_t>();
  surface.row_height = probe::read<double>();
  surface.cell_height = probe::read<std::uint32_t>();
  surface.delivered = probe::read<std::uint8_t>() != 0;
  surface.has_rows = probe::read<std::uint8_t>() != 0;
  const auto x = probe::read<double>();
  const auto y = probe::read<double>();
  ScrollSample sample{.delta = probe::read<double>(), .precise = probe::read<std::uint8_t>() != 0, .phase = probe::read<ScrollPhase>()};
  if (operation == Operation::pointer_up || operation == Operation::pointer_down) {
    sample.delta = operation == Operation::pointer_up ? -1 : 1;
    sample.precise = false;
    sample.phase = ScrollPhase::none;
  }

  probe::write(scroll.consume(state, surface, {.x = x, .y = y}, sample));
}

}

int main() {
  try {
    HistoryScroll scroll;
    while (true) {
      const auto incoming = std::getc(stdin);
      if (incoming == EOF) {
        break;
      }

      const auto operation = static_cast<Operation>(incoming);
      if (operation == Operation::reset) {
        scroll = HistoryScroll{};
      } else {
        record(scroll, operation);
      }
    }

    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
