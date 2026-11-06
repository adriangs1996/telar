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
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <algorithm>
#include <cmath>
#include <limits>
#include "probe_io.hpp"
#include <cstdio>
#include <exception>
#include <iostream>



import telar.gui.presentation.suggestion_labels;
import telar.gui.presentation.application_mark;

namespace {

using namespace telar::gui;
using probe::read;
using probe::write;

enum class Operation : std::uint8_t {
  start,
  observe,
  sample,
  animation,
};

StatusAgeSample readSample() {
  const auto pane_id = read<std::uint64_t>();
  const auto generation = read<std::uint64_t>();
  const auto status = read<std::uint32_t>();
  const auto provider = read<std::uint32_t>();
  const auto seconds = read<std::uint32_t>();

  return {.pane_id = pane_id, .pane_generation = generation, .status = static_cast<telar::AgentStatus>(status), .provider = static_cast<telar::AgentProvider>(provider), .reported_seconds = seconds};
}

void writeClock(const StatusAge &clock, std::uint64_t now_ns) {
  const auto interval = clock.interval();
  write(interval.age_ns);
  write(interval.sampled_ns);
  write(interval.seconds(now_ns));
}

void animation() {
  const auto now_ns = read<std::uint64_t>();
  const auto status = static_cast<telar::AgentStatus>(read<std::uint32_t>());
  const auto connected = read<std::uint32_t>() != 0;
  const auto deadline = AgentAnimation::deadline(status, connected, now_ns);
  write(static_cast<std::uint8_t>(deadline.has_value()));
  write(deadline.value_or(0));
  write(AgentAnimation::alpha(now_ns));
}

}

int main() try {
  StatusAge clock;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      break;
    }

    if (operation == static_cast<int>(Operation::start) || operation == static_cast<int>(Operation::observe)) {
      const auto observed = readSample();
      const auto timestamp = read<std::uint64_t>();
      if (operation == static_cast<int>(Operation::start)) {
        clock = {};
      }

      clock.observe(observed, timestamp);
      writeClock(clock, timestamp);
    } else if (operation == static_cast<int>(Operation::sample)) {
      writeClock(clock, read<std::uint64_t>());
    } else if (operation == static_cast<int>(Operation::animation)) {
      animation();
    } else {
      throw std::invalid_argument{"UnknownClockOperation"};
    }
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
