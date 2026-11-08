#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.tools.probe_io;
import telar.gui.input.child_mouse;

namespace {
using namespace telar;
using namespace telar::gui;
enum class Operation : std::uint8_t {
  reset,
  begin,
  cancel,
  update,
  finish,
  validate,
  capture,
  find,
};

WorkspaceLocation readWorkspace() {
  return {.kind = probe::read<WorkspaceLocation::Kind>(), .id = probe::read<std::uint64_t>()};
}

TabDrag::Position readPoint() {
  return {probe::read<double>(), probe::read<double>()};
}

std::optional<TabDropTarget> readTarget() {
  const auto present = probe::read<std::uint8_t>() != 0;
  const auto relative = probe::read<std::uint8_t>() != 0;
  const auto id = probe::read<std::uint64_t>();
  const auto direction = probe::read<TabMoveDirection>();

  return present ? std::optional{TabDropTarget{.relative_to = relative ? std::optional{id} : std::nullopt, .direction = direction}} : std::nullopt;
}

void writeSource(const std::optional<TabLocation> &source) {
  probe::write(static_cast<std::uint8_t>(source.has_value()));
  probe::write(source ? source->workspace.kind : WorkspaceLocation::Kind::workspace);
  probe::write(source ? source->workspace.id : std::uint64_t{0});
  probe::write(source ? source->tab_id : std::uint64_t{0});
}

void writeTarget(const std::optional<TabDropTarget> &target) {
  probe::write(static_cast<std::uint8_t>(target.has_value()));
  probe::write(static_cast<std::uint8_t>(target && target->relative_to));
  probe::write(target && target->relative_to ? *target->relative_to : std::uint64_t{0});
  probe::write(target ? target->direction : TabMoveDirection::previous);
}

struct Probe {
  TabDrag drag;
  TabDropSlots slots;

  void validate() {
    const auto naming = probe::read<std::uint8_t>() != 0;
    const auto present = probe::read<std::uint8_t>() != 0;
    const auto workspace = readWorkspace();
    const auto count = probe::read<std::uint16_t>();
    std::array<std::uint64_t, TabDropSlots::capacity> ids{};
    if (count > ids.size()) {
      throw std::runtime_error{"TooManyProbeTabs"};
    }
    for (auto &id : std::span{ids}.first(count)) {
      id = probe::read<std::uint64_t>();
    }
    drag.validate(present ? std::optional{workspace} : std::nullopt, std::span{ids}.first(count), naming);
  }

  void capture() {
    const auto count = probe::read<std::uint16_t>();
    std::array<TabDropSlot, TabDropSlots::capacity> entries{};
    std::size_t accepted = 0;
    for (std::uint16_t index = 0; index < count; ++index) {
      const TabDropSlot slot{.id = probe::read<std::uint64_t>(), .bounds = {.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()}};
      const auto layer = probe::read<std::uint8_t>();
      const auto enabled = probe::read<std::uint8_t>() != 0;
      const auto select_tab = probe::read<std::uint8_t>() != 0;
      if (layer == 0 && enabled && select_tab && accepted < entries.size()) {
        entries[accepted++] = slot;
      }
    }
    slots.capture(std::span{entries}.first(accepted));
  }

  void step(Operation operation) {
    std::optional<TabDragMove> move;
    std::optional<TabDropTarget> found;
    switch (operation) {
    case Operation::reset:
      drag = {};
      slots = {};
      break;
    case Operation::begin: {
      const auto workspace = readWorkspace();
      const auto id = probe::read<std::uint64_t>();
      drag.begin({.workspace = workspace, .tab_id = id}, readPoint());
      break;
    }
    case Operation::cancel:
      drag.cancel();
      break;
    case Operation::update: {
      const auto point = readPoint();
      drag.update(point, readTarget());
      break;
    }
    case Operation::finish:
      move = drag.finish();
      break;
    case Operation::validate:
      validate();
      break;
    case Operation::capture:
      capture();
      break;
    case Operation::find:
      found = slots.at(readPoint());
      break;
    }

    probe::write(static_cast<std::uint8_t>(drag.captured()));
    probe::write(static_cast<std::uint8_t>(drag.dragging()));
    writeSource(drag.source());
    writeTarget(drag.destination());
    writeSource(move ? std::optional{move->location} : std::nullopt);
    writeTarget(move ? std::optional{TabDropTarget{.relative_to = move->relative_to, .direction = move->direction}} : std::nullopt);
    writeTarget(found);
    probe::write(static_cast<std::uint16_t>(slots.view().size()));
  }
};
}

int main() try {
  Probe probe;
  for (auto operation = std::getc(stdin); operation != EOF; operation = std::getc(stdin)) {
    probe.step(static_cast<Operation>(operation));
  }
  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';
  return 1;
}
