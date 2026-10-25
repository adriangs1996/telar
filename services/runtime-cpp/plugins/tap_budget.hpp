#pragma once

#include "../exchange_capture/quota.hpp"
#include "limits.hpp"
#include <optional>
#include <utility>

namespace telar::runtime::plugins {

class TapBudget {
public:
  class Charge {
  public:
    explicit Charge(CaptureQuota &quota, std::size_t bytes) noexcept : quota_(quota), bytes_(bytes) {}
    ~Charge() { quota_.release(bytes_); }

    Charge(const Charge &) = delete;
    Charge &operator=(const Charge &) = delete;
    Charge(Charge &&other) noexcept : quota_(other.quota_), bytes_(std::exchange(other.bytes_, 0)) {}

  private:
    CaptureQuota &quota_;
    std::size_t bytes_;
  };

  explicit TapBudget(std::size_t limit = Limits::held_bytes) noexcept : quota_(limit) {}

  std::optional<Charge> charge(std::size_t bytes) noexcept {
    if (!quota_.reserveExact(bytes)) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return std::nullopt;
    }
    return Charge{quota_, bytes};
  }

  std::size_t used() const noexcept { return quota_.used(); }
  std::uint64_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

private:
  CaptureQuota quota_;
  std::atomic<std::uint64_t> dropped_{0};
};

}
