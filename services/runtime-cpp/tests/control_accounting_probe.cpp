#include "terminal/control/engine.hpp"
#include "terminal/ghostty_allocator.hpp"
#include "terminal/effects.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string_view>
#include <vector>

using namespace telar;
using namespace telar::runtime;

namespace {
struct Counters {
  std::uint64_t attempts = 0;
  std::uint64_t requested = 0;
  std::uint64_t successes = 0;
  std::uint64_t failures = 0;
  std::uint64_t frees = 0;
  std::uint64_t freed = 0;
  std::uint64_t live_begin = 0;
  std::uint64_t live_end = 0;
  std::uint64_t peak = 0;
};

// Counts only requests reaching this allocator, including the VT C bridge.
// Direct page mappings and C++ allocations using other allocators are excluded.
class CountingMemory {
public:
  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (!add(phase.attempts, 1) || !add(phase.requested, size)) {
      return nullptr;
    }

    void *result = system_.allocate(size, alignment);
    if (result == nullptr) {
      add(phase.failures, 1);
      return nullptr;
    }

    add(phase.successes, 1);
    add(live_, size);
    phase.live_end = live_;
    phase.peak = std::max(phase.peak, live_);
    return result;
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer == nullptr) {
      return;
    }

    if (size > live_) {
      std::abort();
    }
    system_.deallocate(pointer, size, alignment);
    add(phase.frees, 1);
    add(phase.freed, size);
    live_ -= size;
    phase.live_end = live_;
  }

  void begin() noexcept { phase = {.live_begin = live_, .live_end = live_, .peak = live_}; }
  bool valid() const noexcept { return valid_; }
  Counters phase;

private:
  bool add(std::uint64_t &value, std::size_t count) noexcept {
    if (count > UINT64_MAX - value) {
      valid_ = false;
      return false;
    }
    value += count;
    return true;
  }

  SystemAllocator system_;
  std::uint64_t live_ = 0;
  bool valid_ = true;
};

using Memory = BudgetAllocator<CountingMemory>;

struct Component {
  GhosttyAllocatorBridge<Memory> allocator;
  TerminalHandle terminal;
  RenderStateHandle render;
  TerminalEffects<Memory> effects;
  std::shared_ptr<PtyResponseQueue> responses;
  control::Engine<Memory> controller;

  explicit Component(Memory &memory) : allocator{memory}, effects{memory}, responses{std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory})}, controller{memory, *responses, true} {
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

struct Workload {
  std::span<const Byte> input;
  std::size_t fragment;
  std::uint64_t messages = 0;
  std::uint64_t sink_copy_bytes = 0;
  std::uint64_t output_hash = UINT64_C(14695981039346656037);
};

void execute(Component &probe, Workload &work, std::size_t iterations) {
  std::array<Byte, 65536> output;
  for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
    for (std::size_t offset = 0; offset < work.input.size();) {
      const auto count = std::min(work.fragment == 0 ? work.input.size() : work.fragment, work.input.size() - offset);
      if (probe.controller.feed(work.input.subspan(offset, count)) != count) {
        throw std::runtime_error{"Accounting input was blocked"};
      }
      offset += count;

      const auto batch = probe.responses->peekBatch();
      std::size_t written = 0;
      for (std::size_t index = 0; index < batch.count; ++index) {
        const auto response = batch.message(index);
        if (response.size() > output.size() - written) {
          throw std::runtime_error{"Accounting sink capacity exceeded"};
        }
        std::copy(response.begin(), response.end(), output.data() + written);
        written += response.size();
      }
      work.messages += batch.count;
      work.sink_copy_bytes += written;
      probe.responses->consumeBytes(written);
      for (const auto byte : std::span{output}.first(written)) {
        work.output_hash = (work.output_hash ^ byte) * UINT64_C(1099511628211);
      }
    }
  }
}

std::size_t number(std::string_view input) {
  std::size_t value = 0;
  const auto parsed = std::from_chars(input.data(), input.data() + input.size(), value);
  if (parsed.ec != std::errc{} || parsed.ptr != input.data() + input.size() || value > 100000) {
    throw std::runtime_error{"Invalid accounting argument"};
  }
  return value;
}

void print(const Counters &value) {
  std::printf("{\"attempts\":%llu,\"requested_bytes\":%llu,\"successes\":%llu,\"failures\":%llu,\"frees\":%llu,\"freed_bytes\":%llu,\"live_begin\":%llu,\"live_end\":%llu,\"peak_live\":%llu}", static_cast<unsigned long long>(value.attempts), static_cast<unsigned long long>(value.requested), static_cast<unsigned long long>(value.successes), static_cast<unsigned long long>(value.failures), static_cast<unsigned long long>(value.frees), static_cast<unsigned long long>(value.freed), static_cast<unsigned long long>(value.live_begin), static_cast<unsigned long long>(value.live_end), static_cast<unsigned long long>(value.peak));
}
}

int main(int argc, char **argv) {
  try {
    if (argc != 6) {
      throw std::runtime_error{"Expected input path, iterations, fragment, setup and warmup iterations"};
    }
    const auto iterations = number(argv[2]);
    const auto fragment = number(argv[3]);
    const auto setup = number(argv[4]);
    const auto warmup = number(argv[5]);
    if (setup > 4 || iterations == 0) {
      throw std::runtime_error{"Invalid accounting setup"};
    }
    std::ifstream input{argv[1], std::ios::binary};
    std::vector<Byte> data(1024 * 1024 + 1);
    input.read(reinterpret_cast<char *>(data.data()), data.size());
    if (!input.eof() || input.gcount() == 0 || input.gcount() == static_cast<std::streamsize>(data.size())) {
      throw std::runtime_error{"Accounting input must contain1byte to1MiB"};
    }
    data.resize(static_cast<std::size_t>(input.gcount()));
    CountingMemory counter;
    Memory memory{counter, 64 * 1024 * 1024};
    std::array<Counters, 5> phases;
    Workload work{data, fragment};
    {
      Component probe{memory};
      phases[0] = counter.phase;
      counter.begin();
      probe.controller.policy.checksum_report = setup != 0;
      if (setup >= 2) {
        const std::string_view cell = setup == 2 ? "A" : setup == 3 ? "\x1b[1;3mA\x1b[0mB" : "Á";
        Workload seed{{reinterpret_cast<const Byte *>(cell.data()), cell.size()}, 0};
        execute(probe, seed, setup == 3 ? 80 * 24 / 2 : 80 * 24);
        if (setup == 4) {
          constexpr std::string_view flags = "\x1b[4#y";
          Workload options{{reinterpret_cast<const Byte *>(flags.data()), flags.size()}, 0};
          execute(probe, options, 1);
        }
      }
      phases[1] = counter.phase;
      counter.begin();
      execute(probe, work, warmup);
      phases[2] = counter.phase;
      counter.begin();
      work = {data, fragment};
      execute(probe, work, iterations);
      phases[3] = counter.phase;
      counter.begin();
    }
    phases[4] = counter.phase;
    if (!counter.valid() || memory.liveBytes() != 0 || memory.failures() != 0) {
      throw std::runtime_error{"Accounting overflow, allocation failure or leaked owned bytes"};
    }

    std::printf("{\"version\":1,\"messages\":%llu,\"sink_copy_bytes\":%llu,\"output_fnv1a\":%llu,\"phases\":[", static_cast<unsigned long long>(work.messages), static_cast<unsigned long long>(work.sink_copy_bytes), static_cast<unsigned long long>(work.output_hash));
    for (std::size_t index = 0; index < phases.size(); ++index) {
      if (index != 0) {
        std::putchar(',');
      }
      print(phases[index]);
    }
    std::puts("]}");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
