#pragma once

#include <cstdint>

namespace telar::gui {

struct CalendarSample {
  std::int64_t now_ms = 0;
  std::int16_t utc_offset_min = 0;

  bool operator==(const CalendarSample &) const = default;
};

}
