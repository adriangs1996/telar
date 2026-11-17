#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QTimer>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  inline void scheduleDeadline(QTimer& timer, std::optional<std::uint64_t> deadline_ns, std::uint64_t now_ns) {
    timer.stop();
    if (!deadline_ns) {
      return;
    }

    const auto remaining = *deadline_ns - std::min(*deadline_ns, now_ns);
    constexpr auto unit = application::notifications::NotificationInput::nanoseconds_per_millisecond;
    const auto delay = (remaining / unit) + static_cast<std::uint64_t>(remaining % unit != 0);

    timer.start(static_cast<int>(std::clamp<std::uint64_t>(delay, 1, std::numeric_limits<int>::max())));
  }

}
