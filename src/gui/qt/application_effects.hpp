#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "machine_client_key.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>

#pragma once


import telar.gui.application.host_effects;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

class Application;

struct ApplicationEffects {
  Application &application;
  MachineClientKey source;

  bool postNotification(const NotificationPayload &payload);
  bool playSound(AgentSound sound);
  void notePaneInput(FramePacer::Pane pane, std::uint64_t now_ns) noexcept;
};

}
