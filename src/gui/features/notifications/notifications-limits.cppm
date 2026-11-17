// What the session keeps of a limit it reached: the row it counts in, when it happened, and
// how long and how often the user and the runtime hear of it.
export module telar.gui.features.notifications:limits;

import std;

import telar.gui.foundation.text;

export namespace telar::gui::features::notifications {

  struct LimitNotices {
    static constexpr std::size_t name_capacity = 64;
    static constexpr std::size_t noun_capacity = 32;
    static constexpr std::size_t route_capacity = 32;
    static constexpr std::size_t description_capacity = name_capacity + noun_capacity + 96;
    // How long the notice of a reached limit shows, how soon one limit shows again, and how
    // soon the runtime hears of it again.
    static constexpr std::uint64_t duration_ns = 8'000'000'000;
    static constexpr std::uint64_t notice_interval_ms = 60'000;
    static constexpr std::uint64_t report_interval_ms = 1000;

    using Description = BoundedText<description_capacity>;
  };

  // The row a limit counts in.
  struct LimitSlot {
    std::size_t value = 0;
  };

  // A reach the session counted: its row, and whether the user is to see it now.
  struct LimitRecorded {
    LimitSlot slot{};
    bool show = false;
  };

  // When a reach happened, on the awake clock and on the wall clock.
  struct LimitTime {
    std::int64_t awake_ms = 0;
    std::int64_t real_ms = 0;
  };

}
