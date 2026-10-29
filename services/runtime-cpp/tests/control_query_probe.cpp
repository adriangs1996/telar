#include "terminal/terminal.hpp"
#include <chrono>
#include <memory>

using namespace telar;
using namespace telar::runtime;

namespace {
struct Probe {
  SystemAllocator system;
  BudgetAllocator<SystemAllocator> memory{system, 64 * 1024 * 1024};
  Terminal<BudgetAllocator<SystemAllocator>> terminal;

  explicit Probe(TerminalSize size) : terminal(memory, size, TerminalPurpose::separate_media) {}
};
}

extern "C" void *query_probe_new(std::uint16_t columns, std::uint16_t rows, std::uint16_t width, std::uint16_t height) noexcept {
  try {
    return new Probe{TerminalSize{columns, rows, width, height}};
  } catch (...) {
    return nullptr;
  }
}

extern "C" void query_probe_free(void *context) noexcept {
  delete static_cast<Probe *>(context);
}

extern "C" bool query_probe_feed(void *context, const Byte *bytes, std::size_t size) noexcept {
  try {
    static_cast<Probe *>(context)->terminal.feed({bytes, size});
    return true;
  } catch (...) {
    return false;
  }
}

extern "C" std::size_t query_probe_drain(void *context, Byte *destination, std::size_t capacity) noexcept {
  auto &terminal = static_cast<Probe *>(context)->terminal;
  std::size_t written = 0;
  while (!terminal.responses().empty()) {
    const auto bytes = terminal.responses();
    if (bytes.size() > capacity - written) {
      break;
    }

    std::copy(bytes.begin(), bytes.end(), destination + written);
    written += bytes.size();
    terminal.consumeResponses(bytes.size());
  }

  return written;
}

extern "C" std::uint64_t query_probe_benchmark(const Byte *bytes, std::size_t size, std::size_t iterations, std::size_t fragment) noexcept {
  try {
    Probe probe{TerminalSize{80, 24, 9, 18}};
    std::array<Byte, 65536> output;
    const auto started = std::chrono::steady_clock::now();
    for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
      for (std::size_t offset = 0; offset < size;) {
        const auto count = std::min(fragment == 0 ? size : fragment, size - offset);
        probe.terminal.feed({bytes + offset, count});
        offset += count;
        query_probe_drain(&probe, output.data(), output.size());
      }
    }

    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  } catch (...) {
    return 0;
  }
}
