#pragma once

#include <atomic>
#include <cstdint>
#include <limits>

namespace telar::gui {

struct GraphicsLifetime {
  std::uint64_t value = 0;

  [[nodiscard]] static GraphicsLifetime next() noexcept {
    static std::atomic<std::uint64_t> next_value{1};
    auto candidate = next_value.load(std::memory_order_relaxed);
    while (candidate != std::numeric_limits<std::uint64_t>::max()) {
      if (next_value.compare_exchange_weak(candidate, candidate + 1, std::memory_order_relaxed)) {
        return {.value = candidate};
      }
    }

    return {};
  }

  [[nodiscard]] bool cacheable() const noexcept {
    return value != 0;
  }

  bool operator==(const GraphicsLifetime &) const noexcept = default;
};

}
