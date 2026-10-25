#pragma once

#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>

namespace telar::runtime {

class CaptureQuota {
public:
  explicit CaptureQuota(std::size_t limit) noexcept : limit_(limit) {}

  bool reserveExact(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);
    while (requested <= limit_ - current) {
      if (used_.compare_exchange_weak(current, current + requested, std::memory_order_relaxed)) {
        return true;
      }
    }
    return false;
  }

  std::size_t reserveAtMost(std::size_t requested) noexcept {
    auto current = used_.load(std::memory_order_relaxed);
    for (;;) {
      const auto granted = std::min(requested, limit_ - current);
      if (granted == 0 || used_.compare_exchange_weak(current, current + granted, std::memory_order_relaxed)) {
        return granted;
      }
    }
  }

  void release(std::size_t bytes) noexcept {
    if (bytes == 0) {
      return;
    }
    [[maybe_unused]] const auto previous = used_.fetch_sub(bytes, std::memory_order_relaxed);
    assert(previous >= bytes);
  }

  std::size_t used() const noexcept { return used_.load(std::memory_order_relaxed); }

private:
  const std::size_t limit_;
  std::atomic<std::size_t> used_{0};
};

}
