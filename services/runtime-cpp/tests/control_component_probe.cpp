#include "terminal/control/engine.hpp"
#include "terminal/ghostty_allocator.hpp"
#include "terminal/effects.hpp"
#include <chrono>

using namespace telar;
using namespace telar::runtime;

namespace {
struct ComponentProbe {
  SystemAllocator system;
  BudgetAllocator<SystemAllocator> memory{system, 64 * 1024 * 1024};
  GhosttyAllocatorBridge<decltype(memory)> allocator{memory};
  TerminalHandle terminal;
  RenderStateHandle render;
  TerminalEffects<decltype(memory)> effects{memory};
  std::shared_ptr<PtyResponseQueue> responses = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, decltype(memory)>{memory});
  control::Engine<decltype(memory)> controller{memory, *responses, true};

  ComponentProbe() {
    checkGhostty(ghostty_terminal_new(allocator.get(), terminal.output(), 80, 24));
    checkGhostty(ghostty_render_state_new(allocator.get(), render.output()));
    const GhosttyColorRgb foreground{255, 255, 255};
    const GhosttyColorRgb background{0, 0, 0};
    const bool blink = true;
    const bool disabled = false;
    checkGhostty(ghostty_terminal_set(terminal.get(), GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    checkGhostty(ghostty_terminal_set(terminal.get(), GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    checkGhostty(ghostty_terminal_set(terminal.get(), GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink));
    checkGhostty(ghostty_terminal_set(terminal.get(), GHOSTTY_TERMINAL_OPT_KITTY_PROTOCOL, &disabled));
    checkGhostty(ghostty_terminal_resize(terminal.get(), 80, 24, 9, 18));
    controller.bind(terminal.get(), render.get(), true);
    controller.configureSize({80, 24, 9, 18});
  }
};

volatile std::uint64_t observed_output;
}

static std::uint64_t benchmarkComponent(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment, bool checksum) noexcept {
  try {
    ComponentProbe probe;
    probe.controller.policy.checksum_report = checksum;
    std::array<Byte, 65536> output;
    std::uint64_t observed = 0;
    const auto started = std::chrono::steady_clock::now();
    for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
      for (std::size_t offset = 0; offset < size;) {
        const auto count = std::min(fragment == 0 ? size : fragment, size - offset);
        if (probe.controller.feed({bytes + offset, count}) != count) {
          return 0;
        }
        offset += count;
        std::size_t written = 0;
        const auto batch = probe.responses->peekBatch();
        for (const auto response : std::span{batch.messages}.first(batch.count)) {
          if (response.size() > output.size() - written) {
            return 0;
          }
          std::copy(response.begin(), response.end(), output.data() + written);
          written += response.size();
        }
        probe.responses->consumeBytes(written);
        if (written != 0) {
          observed += output.front() + output[written - 1];
        }
      }
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    observed_output = observed;
    return elapsed;
  } catch (...) {
    return 0;
  }
}

extern "C" std::uint64_t query_probe_benchmark_component(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, false);
}

extern "C" std::uint64_t query_probe_benchmark_component_checksum(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, true);
}
