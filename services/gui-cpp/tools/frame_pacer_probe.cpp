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
#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>



import telar.gui.presentation.frame_pacer;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  configure,
  input,
  deadline,
  record,
};

FramePacer::Pane readPane() {
  const auto pane_id = probe::read<std::uint64_t>();
  const auto frame_id = probe::read<std::uint64_t>();
  const auto generation = probe::read<std::uint64_t>();
  const auto attached = probe::read<std::uint8_t>() != 0;

  return {.pane_id = pane_id, .frame_id = frame_id, .attached = attached, .attachment_generation = generation};
}

void configure(FramePacer &pacer) {
  const auto display_interval = probe::read<std::uint64_t>();
  const auto capped = probe::read<std::uint8_t>() != 0;
  const auto fps = probe::read<std::uint16_t>();
  pacer.configure(display_interval, capped ? std::optional{fps} : std::nullopt);
}

void observe(FramePacer &pacer, Operation operation) {
  const auto now_ns = probe::read<std::uint64_t>();
  const auto count = probe::read<std::uint8_t>();
  std::array<FramePacer::Pane, FramePacer::capacity> storage{};
  if (count > storage.size()) {
    throw std::invalid_argument{"TooManyFramePacerPanes"};
  }

  const auto panes = std::span{storage}.first(count);
  for (auto &pane : panes) {
    pane = readPane();
  }

  if (operation == Operation::record) {
    pacer.record(panes, now_ns);
  }

  const auto deadline = pacer.waitUntil(panes, now_ns);
  probe::write(static_cast<std::uint8_t>(deadline.has_value()));
  probe::write(deadline.value_or(0));
}

}

int main() try {
  FramePacer pacer;
  while (true) {
    const auto next = std::getchar();
    if (next == EOF) {
      return 0;
    }

    const auto operation = static_cast<Operation>(next);
    switch (operation) {
    case Operation::reset:
      pacer = {};
      break;
    case Operation::configure:
      configure(pacer);
      break;
    case Operation::input: {
      const auto now_ns = probe::read<std::uint64_t>();
      pacer.noteInput(readPane(), now_ns);
      break;
    }
    case Operation::deadline:
    case Operation::record:
      observe(pacer, operation);
      break;
    default:
      throw std::invalid_argument{"UnknownFramePacerOperation"};
    }

    probe::write(pacer.interval());
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
