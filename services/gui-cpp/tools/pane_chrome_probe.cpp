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
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "telar_client/serializers/telar_protocol.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.core.metrics;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;

enum class Operation : std::uint8_t {
  geometry,
  status,
  progress,
};

void writeText(std::string_view text) {
  probe::write(static_cast<std::uint8_t>(text.size()));
  for (const auto character : text) {
    probe::write(character);
  }
}

void geometry() {
  const auto area = probe::readRect();
  const auto ratio = probe::read<float>();
  const auto height = probe::read<std::uint32_t>();
  const PaneHeaderMeasurements measurements{
      .index = probe::read<float>(),
      .name = probe::read<float>(),
      .chip = probe::read<float>(),
      .paused = probe::read<float>(),
      .progress = probe::read<float>(),
      .compact_progress = probe::read<float>(),
      .needs_attention = probe::read<std::uint8_t>() != 0,
  };
  const auto result = PaneHeaderGeometry::derive(area, {.ratio = ratio, .maximum_band_height = static_cast<float>(height)}, measurements);
  probe::write(static_cast<std::uint8_t>(result.compact_progress));
  probe::writeRect(result.progress);
  probe::writeRect(result.index);
  probe::writeRect(result.name);
  probe::writeRect(result.paused);
  probe::writeRect(result.chip);
}

void status() {
  const auto state = static_cast<AgentStatus>(probe::read<std::uint8_t>());
  const auto reason = static_cast<AgentBlockedReason>(probe::read<std::uint8_t>());
  const auto seconds = probe::read<std::uint32_t>();
  writeText(PaneStatusChip::text(state, reason, seconds).view());
}

void progress() {
  const auto state = static_cast<PaneProgressState>(probe::read<std::uint8_t>());
  const auto percent = probe::read<std::uint8_t>();
  writeText(PaneProgressPresentation::text(state, percent).view());
}

}

int main() try {
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    switch (static_cast<Operation>(operation)) {
    case Operation::geometry:
      geometry();
      break;
    case Operation::status:
      status();
      break;
    case Operation::progress:
      progress();
      break;
    default:
      throw std::invalid_argument{"UnknownPaneChromeOperation"};
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
