#pragma once

#include "telar_base/diagnostics/timing.hpp"
#include <atomic>
#include <exception>

namespace telar::runtime::diagnostics {

struct OperationSnapshot {
  Timing timing;
  std::uint64_t failures = 0;
};

class OperationCounters {
public:
  void observe(std::uint64_t duration, bool failed) noexcept {
    total_ns_.fetch_add(duration, std::memory_order_relaxed);
    auto maximum = maximum_ns_.load(std::memory_order_relaxed);
    while (duration > maximum && !maximum_ns_.compare_exchange_weak(maximum, duration, std::memory_order_relaxed)) {
    }

    failures_.fetch_add(failed, std::memory_order_relaxed);
    count_.fetch_add(1, std::memory_order_relaxed);
  }

  OperationSnapshot snapshot() const noexcept {
    return {{count_.load(std::memory_order_relaxed), total_ns_.load(std::memory_order_relaxed), maximum_ns_.load(std::memory_order_relaxed)}, failures_.load(std::memory_order_relaxed)};
  }

private:
  std::atomic<std::uint64_t> count_{0};
  std::atomic<std::uint64_t> total_ns_{0};
  std::atomic<std::uint64_t> maximum_ns_{0};
  std::atomic<std::uint64_t> failures_{0};
};

class OperationTimer {
public:
  using Clock = std::chrono::steady_clock;

  explicit OperationTimer(OperationCounters *counters) noexcept
      : counters_(counters), started_(counters == nullptr ? Clock::time_point{} : Clock::now()), exceptions_(std::uncaught_exceptions()) {}

  ~OperationTimer() {
    if (counters_ != nullptr) {
      counters_->observe(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started_).count(), failed_ || std::uncaught_exceptions() > exceptions_);
    }
  }

  OperationTimer(const OperationTimer &) = delete;
  OperationTimer &operator=(const OperationTimer &) = delete;

  void fail() noexcept {
    failed_ = true;
  }

private:
  OperationCounters *counters_;
  Clock::time_point started_;
  int exceptions_;
  bool failed_ = false;
};

}
