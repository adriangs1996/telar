#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "probe_io.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>



import telar.gui.application.sound_playback;
import telar.gui.core.unicode_scalar;

namespace {

using namespace telar;
using namespace telar::gui;

CellRectangle readRectangle() {
  return {.x = probe::read<std::uint16_t>(), .y = probe::read<std::uint16_t>(), .width = probe::read<std::uint16_t>(), .height = probe::read<std::uint16_t>()};
}

void writeRectangle(CellRectangle area) {
  probe::write(area.x);
  probe::write(area.y);
  probe::write(area.width);
  probe::write(area.height);
}

PaneLayout readLayout() {
  const auto count = probe::read<std::uint8_t>();
  if (count > PaneLayout::maximum_nodes) {
    throw std::length_error{"PaneGridProbeNodeCapacity"};
  }

  std::array<ClientLayoutNode, PaneLayout::maximum_nodes> nodes;
  for (auto &node : std::span{nodes}.first(count)) {
    const auto kind = probe::read<std::uint8_t>();
    if (kind == 0) {
      node = ClientLayoutPane{probe::read<std::uint64_t>()};
    } else if (kind == 1) {
      node = ClientLayoutSplit{.axis = static_cast<ClientLayoutAxis>(probe::read<std::uint8_t>()), .ratio = probe::read<std::uint16_t>()};
    } else {
      throw std::invalid_argument{"UnknownPaneGridNode"};
    }
  }

  PaneLayout layout;
  layout.restore(std::span{nodes}.first(count));

  return layout;
}

void writeLayout(const PaneLayout &layout) {
  probe::write(static_cast<std::uint8_t>(layout.nodes().size()));
  for (const auto &node : layout.nodes()) {
    if (const auto *pane = std::get_if<ClientLayoutPane>(&node)) {
      probe::write(std::uint8_t{0});
      probe::write(pane->pane_id);
    } else {
      const auto split = std::get<ClientLayoutSplit>(node);
      probe::write(std::uint8_t{1});
      probe::write(static_cast<std::uint8_t>(split.axis));
      probe::write(split.ratio);
    }
  }
}

void frame() {
  const auto area = readRectangle();
  const PaneLayout::Metrics metrics{.border = probe::read<std::uint8_t>(), .gap = probe::read<std::uint8_t>()};
  const auto fullscreen = probe::read<std::uint8_t>() != 0;
  const auto focused = probe::read<std::uint64_t>();
  auto layout = readLayout();
  const auto fullscreen_pane = fullscreen ? std::optional{focused} : std::nullopt;
  const auto placements = layout.arrange(area, metrics, fullscreen_pane);
  probe::write(static_cast<std::uint8_t>(layout.hasBorders(fullscreen, metrics)));
  probe::write(static_cast<std::uint8_t>(placements.size()));
  for (const auto &placement : placements) {
    probe::write(placement.pane_id);
    probe::write(placement.display_index);
    probe::write(static_cast<std::uint8_t>(placement.pane_id == focused));
    writeRectangle(placement.bounds);
    writeRectangle(placement.content);
  }

  std::array<std::uint64_t, PaneLayout::maximum_panes> visible{};
  const auto visible_count = placements.size();
  for (std::size_t index = 0; index < visible_count; ++index) {
    visible[index] = placements[index].pane_id;
  }

  for (const auto pane_id : std::span{visible}.first(visible_count)) {
    for (const auto axis : {ClientLayoutAxis::horizontal, ClientLayoutAxis::vertical}) {
      const auto proposed = layout.prospectiveSplit(area, axis, pane_id, metrics, fullscreen_pane);
      probe::write(static_cast<std::uint8_t>(proposed.has_value()));
      if (proposed) {
        writeRectangle(proposed->existing_content);
        writeRectangle(proposed->added_content);
      }
    }
  }

  constexpr std::array directions{PaneDirection::left, PaneDirection::right, PaneDirection::up, PaneDirection::down};
  for (const auto direction : directions) {
    probe::write(layout.focusTarget(area, metrics, {.pane_id = focused, .direction = direction, .fullscreen = fullscreen}));
  }

  for (const auto direction : directions) {
    auto resized = layout;
    probe::write(static_cast<std::uint8_t>(resized.resize(focused, direction, area, metrics)));
    writeLayout(resized);
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
      throw std::invalid_argument{"UnknownPaneGridOperation"};
    }

    frame();
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
