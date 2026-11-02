#include "core/geometry.hpp"
#include "history/choice.hpp"
#include "input/history_action_capture.hpp"
#include "input/history_hover.hpp"
#include "presentation/history_actions.hpp"
#include "probe_io.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <span>
#include <variant>

namespace {

using namespace telar::gui;
enum class Operation : std::uint8_t { reset, frame, press, release, cancel, move, drag, leave };
enum class Kind : std::uint8_t { row, card };
enum class OutputKind : std::uint8_t { none, row, card };
enum class Slot : std::uint8_t { first_row, second_row, copy, erase, visit, count };

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
      const Rect bounds{.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()};
      const bool present = probe::read<std::uint8_t>() != 0;
      static_cast<void>(probe::read<std::uint8_t>());
      if (present) {
        auto &target = prepared[size++];
        target.identity.generation = generation;
        target.identity.action = kind == Kind::row ? decltype(target.identity.action){HistoryChoice{.index = static_cast<std::size_t>(index), .revision = revision}} : decltype(target.identity.action){static_cast<HistoryCardAction>(index)};
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
    if (const auto &identity = hover.hovered()) {
      generation = identity->generation;
      if (const auto *row = std::get_if<HistoryChoice>(&identity->action)) {
        kind = OutputKind::row;
        index = row->index;
        revision = row->revision;
      } else {
        kind = OutputKind::card;
        index = static_cast<std::uint64_t>(std::get<HistoryCardAction>(identity->action));
      }
    }

    probe::write(kind);
    probe::write(index);
    probe::write(revision);
    probe::write(generation);
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
