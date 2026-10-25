#pragma once

#include <chrono>
#include <cstdint>

namespace telar::runtime {

struct ObservationTime {
  std::int64_t milliseconds = 0;
  std::int64_t nanoseconds = 0;

  static ObservationTime now() noexcept {
    return {std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count(), std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()};
  }

  bool before(ObservationTime other) const noexcept {
    return nanoseconds != 0 && other.nanoseconds != 0 ? nanoseconds < other.nanoseconds : milliseconds < other.milliseconds;
  }
};

}
