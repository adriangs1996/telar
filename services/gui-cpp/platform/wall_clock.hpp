#pragma once

#include "core/calendar_sample.hpp"

namespace telar::gui::platform {

struct WallClock {
  [[nodiscard]] static CalendarSample sample() noexcept;
};

}
