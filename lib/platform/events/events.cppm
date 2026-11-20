export module telar.platform.events;

import std;
import telar.base.ds;

// Interface: telar_platform/observation_time.cppm
export {
  namespace telar::runtime {

    struct ObservationTime {
      std::int64_t milliseconds = 0;
      std::int64_t nanoseconds = 0;

      static ObservationTime now() noexcept;
      [[nodiscard]] bool before(ObservationTime other) const noexcept;
    };

  }
}

// Interface: telar_platform/earliest.cppm
export {
  namespace telar::runtime {

    // The sooner of two optional deadlines; none only when neither is set.
    template <typename Time>
    constexpr ds::Option<Time> earliest(const ds::Option<Time>& left, const ds::Option<Time>& right) noexcept {
      return left && right ? ds::Option{std::min(*left, *right)} : left ? left
                                                                        : right;
    }

  }
}
