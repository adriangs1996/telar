module telar.platform.events;

import std;

namespace telar::runtime {

  ObservationTime ObservationTime::now() noexcept {
    return {.milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count(), .nanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()};
  }

  bool ObservationTime::before(ObservationTime other) const noexcept {
    return nanoseconds != 0 && other.nanoseconds != 0 ? nanoseconds < other.nanoseconds : milliseconds < other.milliseconds;
  }

}
