#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <QTimer>
#include <optional>

#pragma once


import telar.gui.application.workspace_replica;

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
