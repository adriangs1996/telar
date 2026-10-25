#pragma once

#include <chrono>
#include <cstdint>

namespace telar::runtime {

class ProxyConnectionPolicy {
public:
  using Clock = std::chrono::steady_clock;
  using Time = Clock::time_point;

  static constexpr std::size_t capacity = 256;
  static constexpr std::size_t maximum_unauthenticated = 64;
  static constexpr auto head_timeout = std::chrono::seconds{10};
  static constexpr auto establishment_timeout = std::chrono::seconds{30};
  static constexpr auto half_closed_timeout = std::chrono::seconds{60};
  static constexpr auto evictable_head_age = std::chrono::seconds{1};
  static constexpr auto evictable_idle_age = std::chrono::seconds{60};
  static constexpr auto evictable_silent_age = std::chrono::minutes{10};

  enum class Phase {
    connect_head,
    establishing,
    open,
    idle,
    half_closed,
    closing
  };

  enum class Closure {
    none,
    head_timeout,
    establishment_timeout,
    half_closed_timeout,
    evict_head,
    evict_idle,
    evict_silent
  };

  explicit ProxyConnectionPolicy(Time now) noexcept
      : since_(now),
        active_(now) {}

  void enter(Phase phase, Time now) noexcept {
    if (phase_ != phase) {
      phase_ = phase;
      since_ = now;
    }
  }

  void touch(Time now) noexcept {
    active_ = now;
  }

  void exchanges(std::uint32_t count) noexcept {
    exchanges_ = count;
  }

  Phase phase() const noexcept {
    return phase_;
  }

  Time since() const noexcept {
    return since_;
  }

  Time active() const noexcept {
    return active_;
  }

  Closure expired(Time now) const noexcept {
    switch (phase_) {
    case Phase::connect_head:
      return now - since_ >= head_timeout ? Closure::head_timeout : Closure::none;
    case Phase::establishing:
      return now - since_ >= establishment_timeout ? Closure::establishment_timeout : Closure::none;
    case Phase::half_closed:
      return now - active_ >= half_closed_timeout ? Closure::half_closed_timeout : Closure::none;
    default:
      return Closure::none;
    }
  }

  bool evictable(Closure reason, Time now) const noexcept {
    switch (reason) {
    case Closure::evict_head:
      return phase_ == Phase::connect_head && now - since_ >= evictable_head_age;
    case Closure::evict_idle:
      return phase_ == Phase::idle && exchanges_ == 0 && now - active_ >= evictable_idle_age;
    case Closure::evict_silent:
      return phase_ == Phase::open && exchanges_ == 0 && now - active_ >= evictable_silent_age;
    default:
      return false;
    }
  }

private:
  Phase phase_ = Phase::connect_head;
  Time since_;
  Time active_;
  std::uint32_t exchanges_ = 0;
};

}
