#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <array>
#include <string_view>
#include <optional>
#include <utility>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <span>
#include <variant>
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.input.child_mouse;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.presentation.history_meta_geometry;

namespace {

using namespace telar::gui;
enum class Operation : std::uint8_t { reset, frame, press, release, cancel, move, drag, leave };
enum class Kind : std::uint8_t { row, card, footer, filter };
enum class OutputKind : std::uint8_t { none, row, card, footer, filter };
enum class Slot : std::uint8_t { first_row, second_row, copy, erase, visit, submit, alternate, inspect, footer_visit, global, workspace, cwd, pane, human, agent, all, failed, count };

struct Probe {
  std::array<HistoryHoverTarget, static_cast<std::size_t>(Slot::count)> targets{};
  std::size_t count = 0;
  HistoryHover hover;

  void frame() {
    const bool delivered = probe::read<std::uint8_t>() != 0;
    const auto generation = probe::read<std::uint64_t>();
    decltype(targets) prepared{};
    std::size_t size = 0;
    for ([[maybe_unused]] const auto &slot : targets) {
      const auto kind = probe::read<Kind>();
      const auto index = probe::read<std::uint64_t>();
      const auto revision = probe::read<std::uint64_t>();
      const auto selection = probe::read<std::uint64_t>();
      const Rect bounds{.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()};
      const bool present = probe::read<std::uint8_t>() != 0;
      static_cast<void>(probe::read<std::uint8_t>());
      if (present) {
        auto &target = prepared[size++];
        target.identity.generation = generation;
        switch (kind) {
        case Kind::row: target.identity.action = HistoryChoice{.index = static_cast<std::size_t>(index), .revision = revision}; break;
        case Kind::card: target.identity.action = static_cast<HistoryCardAction>(index); break;
        case Kind::filter: target.identity.action = static_cast<HistoryFilterAction>(index); break;
        case Kind::footer: target.identity.action = HistoryFooterIdentity{.action = static_cast<HistoryFooterAction>(index), .choice = {.index = static_cast<std::size_t>(selection), .revision = revision}}; break;
        }
        target.bounds = bounds;
      }
    }

    if (delivered) {
      targets = prepared;
      count = size;
      hover.present(std::span{targets}.first(count));
    }
  }

  void pointer(Operation operation) {
    static_cast<void>(probe::read<std::uint8_t>());
    const HistoryActionPosition position{.x = probe::read<double>(), .y = probe::read<double>()};
    auto observation = HistoryHover::Observation::point;
    if (operation == Operation::leave) {
      observation = HistoryHover::Observation::leave;
    } else if (operation == Operation::release || operation == Operation::drag) {
      observation = HistoryHover::Observation::retained;
    }
    hover.observe(std::span{targets}.first(count), position, observation);
  }

  void write() const {
    auto kind = OutputKind::none;
    std::uint64_t index = 0;
    std::uint64_t revision = 0;
    std::uint64_t generation = 0;
    std::uint64_t selection = 0;
    if (const auto &identity = hover.hovered()) {
      generation = identity->generation;
      if (const auto *row = std::get_if<HistoryChoice>(&identity->action)) {
        kind = OutputKind::row;
        index = row->index;
        revision = row->revision;
      } else if (const auto *card = std::get_if<HistoryCardAction>(&identity->action)) {
        kind = OutputKind::card;
        index = static_cast<std::uint64_t>(*card);
      } else if (const auto *filter = std::get_if<HistoryFilterAction>(&identity->action)) {
        kind = OutputKind::filter;
        index = static_cast<std::uint64_t>(*filter);
      } else if (const auto *footer = std::get_if<HistoryFooterIdentity>(&identity->action)) {
        kind = OutputKind::footer;
        index = static_cast<std::uint64_t>(footer->action);
        if (footer->submission()) {
          revision = footer->choice.revision;
          selection = footer->choice.index;
        }
      }
    }

    probe::write(kind);
    probe::write(index);
    probe::write(revision);
    probe::write(generation);
    probe::write(selection);
  }
};

}

int main() try {
  Probe state;
  for (auto incoming = std::getc(stdin); incoming != EOF; incoming = std::getc(stdin)) {
    const auto operation = static_cast<Operation>(incoming);
    switch (operation) {
    case Operation::reset: state = {}; break;
    case Operation::frame: state.frame(); break;
    case Operation::cancel: state.hover.cancel(); break;
    default: state.pointer(operation); break;
    }

    state.write();
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
