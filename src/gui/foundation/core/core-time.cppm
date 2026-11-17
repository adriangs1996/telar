export module telar.gui.foundation.core:time;

import std;

// Interface: core/calendar_sample.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct CalendarSample {
      std::int64_t now_ms = 0;
      std::int16_t utc_offset_min = 0;

      bool operator==(const CalendarSample&) const = default;
    };

  }
}

// Interface: core/monotonic_clock.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    template <typename Clock>
    concept MonotonicClock = requires {
      { Clock::nowNanoseconds() } noexcept -> std::same_as<std::uint64_t>;
    };

  }
}
