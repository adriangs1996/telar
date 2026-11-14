#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_client_key.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <variant>

#pragma once

import telar.gui.text.notification_payload;
import telar.gui.application.host_effects;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

  class Application;

  struct ApplicationEffects final : HostEffects {
    ApplicationEffects(Application& owner, MachineClientKey client) noexcept
        : application(owner),
          source(client) {}

    bool postNotification(const NotificationPayload& payload) override;
    bool playSound(AgentSound sound) override;
    void notePaneInput(FramePacer::Pane pane) noexcept override;

    Application& application;
    MachineClientKey source;
  };

}
