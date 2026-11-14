export module telar.platform.events;

import std;

// Interface: telar_platform/observation_time.cppm
export {
  namespace telar::runtime {

    struct ObservationTime {
      std::int64_t milliseconds = 0;
      std::int64_t nanoseconds = 0;

      static ObservationTime now() noexcept;
      bool before(ObservationTime other) const noexcept;
    };

  }
}

// Interface: telar_platform/earliest.cppm
export {
  namespace telar::runtime {

    // The sooner of two optional deadlines; none only when neither is set.
    template <typename Time>
    constexpr std::optional<Time> earliest(const std::optional<Time>& left, const std::optional<Time>& right) noexcept {
      return left && right ? std::optional{std::min(*left, *right)} : left ? left
                                                                           : right;
    }

  }
}
