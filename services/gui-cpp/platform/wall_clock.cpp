#include "wall_clock.hpp"
#include "core/calendar_sample.hpp"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <ctime>

namespace telar::gui::platform {

CalendarSample WallClock::sample() noexcept {
  const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  const auto seconds = std::time(nullptr);
  if (seconds == static_cast<std::time_t>(-1)) {
    return {.now_ms = milliseconds};
  }

  std::tm local{};
  std::tm utc{};
  if (localtime_r(&seconds, &local) == nullptr || gmtime_r(&seconds, &utc) == nullptr) {
    return {.now_ms = milliseconds};
  }

  constexpr int minutes_per_hour = 60;
  constexpr int hours_per_day = 24;
  constexpr int maximum_offset_hours = 14;
  constexpr int maximum_offset_minutes = maximum_offset_hours * minutes_per_hour;
  auto day_delta = local.tm_yday - utc.tm_yday;
  if (local.tm_year != utc.tm_year) {
    day_delta = local.tm_year > utc.tm_year ? 1 : -1;
  }

  const auto offset = (day_delta * hours_per_day * minutes_per_hour) + ((local.tm_hour - utc.tm_hour) * minutes_per_hour) + local.tm_min - utc.tm_min;

  return {.now_ms = milliseconds, .utc_offset_min = static_cast<std::int16_t>(std::clamp(offset, -maximum_offset_minutes, maximum_offset_minutes))};
}

}
