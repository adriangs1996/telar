#pragma once

#include <chrono>
#include <concepts>
#include <cstdint>

namespace telar::runtime {

template <typename Clock>
concept CaptureClock = requires {
  { Clock::now() } noexcept -> std::same_as<std::int64_t>;
};

struct CaptureWallClock {
  static std::int64_t now() noexcept {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }
};

}
