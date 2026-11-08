#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>

import std;
import telar.gui.tools.probe_io;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.input.child_mouse;

namespace {

using namespace telar::gui;
enum class Operation : std::uint8_t { reset, frame, press, release, cancel };
enum class Button : std::uint8_t { left, middle, right, count };

HistoryActionSurface readSurface() {
  HistoryActionSurface result{.generation = probe::read<std::uint64_t>()};
  for (auto &target : result.targets) {
    target.action = probe::read<HistoryCardAction>();
    target.bounds = {.x = probe::read<float>(), .y = probe::read<float>(), .width = probe::read<float>(), .height = probe::read<float>()};
    const bool present = probe::read<std::uint8_t>() != 0;
    target.enabled = probe::read<std::uint8_t>() != 0;
    if (!present) {
      target.bounds = {};
    }
  }

  return result;
}

struct Probe {
  HistoryActionSurface surface;
  std::array<HistoryActionCapture, static_cast<std::size_t>(Button::count)> captures{};

  void frame() {
    const bool delivered = probe::read<std::uint8_t>() != 0;
    const auto prepared = readSurface();
    if (!delivered) {
      return;
    }

    surface = prepared;
    for (auto &capture : captures) {
      capture.present(surface);
    }
  }

  void pointer(Operation operation) {
    const auto button = probe::read<Button>();
    const HistoryActionPosition position{.x = probe::read<double>(), .y = probe::read<double>()};
    auto &capture = captures.at(static_cast<std::size_t>(button));
    if (operation == Operation::press) {
      consumed = capture.begin(surface, position, button == Button::left);

      return;
    }

    consumed = capture.held();
    if (const auto action = capture.release(surface, position)) {
      activated = static_cast<std::uint8_t>(static_cast<std::uint8_t>(*action) + 1);
    }
  }

  void step(Operation operation) {
    consumed = false;
    activated = 0;
    switch (operation) {
    case Operation::reset: surface = {}; captures = {}; break;
    case Operation::frame: frame(); break;
    case Operation::press:
    case Operation::release: pointer(operation); break;
    case Operation::cancel:
      for (auto &capture : captures) {
        capture.cancel();
      }
      break;
    }

    std::uint8_t held = 0;
    for (std::size_t index = 0; index < captures.size(); ++index) {
      if (captures[index].held()) {
        held |= static_cast<std::uint8_t>(1U << index);
      }
    }

    probe::write(static_cast<std::uint8_t>(consumed));
    probe::write(activated);
    probe::write(held);
  }

  bool consumed = false;
  std::uint8_t activated = 0;
};

}

int main() try {
  Probe state;
  for (auto incoming = std::getc(stdin); incoming != EOF; incoming = std::getc(stdin)) {
    state.step(static_cast<Operation>(incoming));
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
