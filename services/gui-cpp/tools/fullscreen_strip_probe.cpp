#include "application/pane_layout.hpp"
#include "core/geometry.hpp"
#include "presentation/fullscreen_strip_geometry.hpp"
#include "probe_geometry.hpp"
#include "probe_io.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <span>
#include <stdexcept>

namespace {

using namespace telar::gui;

void geometry() {
  const auto row = probe::readRect();
  const FullscreenStripMetrics metrics{.ratio = probe::read<float>(), .maximum_band_height = static_cast<float>(probe::read<std::uint32_t>()), .mark_side = probe::read<float>()};
  const FullscreenStripMeasurements measurements{.chip = probe::read<float>(), .progress = probe::read<float>(), .compact_progress = probe::read<float>()};
  const auto count = probe::read<std::uint8_t>();
  std::array<FullscreenEntryMeasure, PaneLayout::maximum_panes> sizes{};
  if (count == 0 || count > sizes.size()) {
    throw std::length_error{"InvalidFullscreenEntryCount"};
  }

  for (auto &size : std::span{sizes}.first(count)) {
    size = {.index = probe::read<float>(), .name = probe::read<float>(), .focused = probe::read<std::uint8_t>() != 0, .attention = probe::read<std::uint8_t>() != 0};
  }

  const auto plan = FullscreenStripGeometry::derive(row, metrics, std::span{sizes}.first(count), measurements);
  probe::write(static_cast<std::uint8_t>(plan.compact_progress));
  probe::writeRect(plan.chip);
  probe::writeRect(plan.progress);
  probe::writeRect(plan.leave);
  std::size_t visible = 0;
  for (std::size_t source = 0; source < count; ++source) {
    const bool present = visible < plan.count && plan.entries[visible].source == source;
    const auto entry = present ? plan.entries[visible++] : FullscreenStripGeometry::Entry{};
    probe::write(static_cast<std::uint8_t>(present));
    probe::writeRect(sizes[source].focused ? Rect{} : entry.bounds);
    probe::writeRect(entry.mark.width > 0 ? entry.mark : Rect{});
    probe::writeRect(entry.index);
    probe::writeRect(entry.name);
    probe::writeRect(entry.attention);
  }
}

}

int main() {
  try {
    for (auto operation = std::getchar(); operation != EOF; operation = std::getchar()) {
      if (operation != 0) {
        throw std::invalid_argument{"UnknownFullscreenProbeOperation"};
      }

      geometry();
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
