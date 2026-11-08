#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_geometry;
import telar.gui.tools.probe_io;
import telar.gui.core.metrics;
import telar.gui.graphics.placeholder;
import telar.gui.presentation.frame_pacer;
import telar.gui.presentation.history_inspection_geometry;

namespace {

using namespace telar::gui;

enum class Operation : std::uint8_t {
  frame,
  alpha,
  end,
  geometry,
  reset,
};

struct Frame {
  static constexpr std::uint64_t nanoseconds_per_second = 1'000'000'000;
  static constexpr std::uint64_t frames_per_second = 60;
  std::uint64_t now = 0;
  std::uint64_t interval = (nanoseconds_per_second / frames_per_second) + 1;
  std::optional<std::uint64_t> deadline;

  void merge(AttentionFrame sample) noexcept {
    if (sample.deadline_ns && (!deadline || *sample.deadline_ns < *deadline)) {
      deadline = sample.deadline_ns;
    }
  }

  void write(const AttentionFades &fades) const {
    probe::write(static_cast<std::uint8_t>(deadline.has_value()));
    probe::write(deadline.value_or(0));
    probe::write(static_cast<std::uint32_t>(fades.size()));
  }
};

PaneAttentionKey readKey() {
  const auto pane = probe::read<std::uint64_t>();

  return {.pane_id = pane, .attachment_generation = probe::read<std::uint64_t>()};
}

void geometry(AttentionFades &fades, Frame &frame) {
  const auto area = probe::readRect();
  const auto ratio = probe::read<float>();
  auto color = probe::read<Color>();
  const auto key = readKey();
  const auto animated = probe::read<std::uint8_t>() != 0;
  if (animated) {
    const auto sample = fades.sample(key, frame.now, frame.interval);
    frame.merge(sample);
    color.a *= sample.alpha;
  }

  const auto ring = PaneAttentionGeometry::derive(area, ratio);
  probe::write(static_cast<std::uint8_t>(!ring.bounds.empty()));
  if (!ring.bounds.empty()) {
    const auto shape = RoundedRectangle::resolve({.x = ring.bounds.width, .y = ring.bounds.height}, {.border = color, .radius = ring.radius, .border_width = ring.width});
    probe::writeRect(ring.bounds);
    probe::write(shape.style.radius);
    probe::write(shape.style.border_width);
    probe::write(shape.style.fill);
    probe::write(shape.style.border);
  }

  frame.write(fades);
}

void execute(Operation operation, AttentionFades &fades, Frame &frame) {
  switch (operation) {
  case Operation::frame:
    frame.now = std::max(frame.now, probe::read<std::uint64_t>());
    frame.interval = probe::read<std::uint64_t>();
    frame.deadline.reset();
    fades.begin();
    break;
  case Operation::alpha: {
    const auto sample = fades.sample(readKey(), frame.now, frame.interval);
    frame.merge(sample);
    probe::write(sample.alpha);
    frame.write(fades);
    break;
  }
  case Operation::end:
    fades.end();
    frame.write(fades);
    break;
  case Operation::geometry:
    geometry(fades, frame);
    break;
  case Operation::reset:
    fades = {};
    frame = {};
    break;
  default:
    throw std::invalid_argument{"UnknownPaneAttentionOperation"};
  }
}

}

int main() {
  try {
    AttentionFades fades;
    Frame frame;
    for (auto code = std::getchar(); code != EOF; code = std::getchar()) {
      execute(static_cast<Operation>(code), fades, frame);
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
