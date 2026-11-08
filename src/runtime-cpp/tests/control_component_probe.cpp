#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.runtime.terminal.control;
import telar.runtime.terminal.text_reader;

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

enum class BenchmarkSetup { ordinary, checksum, checksum_ascii, checksum_styled, checksum_graphemes };

volatile std::uint64_t observed_output;
}

static std::uint64_t benchmarkComponent(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment, BenchmarkSetup setup) noexcept {
  try {
    ComponentProbe probe;
    probe.controller.policy.checksum_report = setup != BenchmarkSetup::ordinary;
    const std::string_view cell = setup == BenchmarkSetup::checksum_ascii ? "A" : setup == BenchmarkSetup::checksum_styled ? "\x1b[1;3mA\x1b[0mB" : "Á";
    const auto seed = [&](std::string_view input) {
      return probe.controller.feed({reinterpret_cast<const Byte *>(input.data()), input.size()}) == input.size();
    };
    if (setup == BenchmarkSetup::checksum_ascii || setup == BenchmarkSetup::checksum_styled || setup == BenchmarkSetup::checksum_graphemes) {
      const auto repeats = setup == BenchmarkSetup::checksum_styled ? 80 * 24 / 2 : 80 * 24;
      for (int index = 0; index < repeats; ++index) {
        if (!seed(cell)) {
          return 0;
        }
      }
      if (setup == BenchmarkSetup::checksum_graphemes && !seed("\x1b[4#y")) {
        return 0;
      }
    }
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
        for (std::size_t index = 0; index < batch.count; ++index) {
          const auto response = batch.message(index);
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
  return benchmarkComponent(bytes, size, iterations, fragment, BenchmarkSetup::ordinary);
}

extern "C" std::uint64_t query_probe_benchmark_component_checksum(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, BenchmarkSetup::checksum);
}

extern "C" std::uint64_t query_probe_benchmark_component_checksum_ascii(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, BenchmarkSetup::checksum_ascii);
}

extern "C" std::uint64_t query_probe_benchmark_component_checksum_styled(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, BenchmarkSetup::checksum_styled);
}

extern "C" std::uint64_t query_probe_benchmark_component_checksum_graphemes(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  return benchmarkComponent(bytes, size, iterations, fragment, BenchmarkSetup::checksum_graphemes);
}
