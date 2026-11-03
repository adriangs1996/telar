#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>

namespace telar::runtime::diagnostics {

inline void accumulate(std::uint64_t &counter, std::uint64_t amount = 1) noexcept {
  counter += std::min(amount, std::numeric_limits<std::uint64_t>::max() - counter);
}

struct Timing {
  std::uint64_t count = 0;
  std::uint64_t total_ns = 0;
  std::uint64_t maximum_ns = 0;

  void observe(std::uint64_t duration) noexcept {
    accumulate(count);
    accumulate(total_ns, duration);
    maximum_ns = std::max(maximum_ns, duration);
  }

  std::uint64_t average() const noexcept {
    return count == 0 ? 0 : total_ns / count;
  }

  void merge(const Timing &sample) noexcept {
    accumulate(count, sample.count);
    accumulate(total_ns, sample.total_ns);
    maximum_ns = std::max(maximum_ns, sample.maximum_ns);
  }
};

class TimedScope {
public:
  using Clock = std::chrono::steady_clock;

  explicit TimedScope(Timing &timing) noexcept
      : TimedScope(&timing) {}

  explicit TimedScope(Timing *timing) noexcept
      : timing_(timing), started_(timing == nullptr ? Clock::time_point{} : Clock::now()) {}

  ~TimedScope() {
    if (timing_ != nullptr) {
      timing_->observe(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started_).count());
    }
  }

  TimedScope(const TimedScope &) = delete;
  TimedScope &operator=(const TimedScope &) = delete;

private:
  Timing *timing_;
  Clock::time_point started_;
};

}
