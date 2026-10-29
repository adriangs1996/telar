#pragma once

#include "application/notification_item.hpp"
#include <QTimer>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui::qt {

inline void scheduleDeadline(QTimer &timer, std::optional<std::uint64_t> deadline_ns, std::uint64_t now_ns) {
  timer.stop();
  if (!deadline_ns) {
    return;
  }

  const auto remaining = *deadline_ns - std::min(*deadline_ns, now_ns);
  constexpr auto unit = NotificationInput::nanoseconds_per_millisecond;
  const auto delay = (remaining / unit) + static_cast<std::uint64_t>(remaining % unit != 0);
  timer.start(static_cast<int>(std::clamp<std::uint64_t>(delay, 1, std::numeric_limits<int>::max())));
}

}
