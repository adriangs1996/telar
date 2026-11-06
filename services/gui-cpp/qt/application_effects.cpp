#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application_effects.hpp"
#include "application.hpp"
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
#include "command_process.hpp"
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
#include <exception>
#include <utility>



import telar.gui.application.host_effects;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

bool ApplicationEffects::postNotification(const NotificationPayload &payload) {
  return application.findClient(source) != nullptr && source.machine.slot == application.machines_.active() && application.system_notifier_.post(payload);
}

bool ApplicationEffects::playSound(AgentSound sound) {
  if (application.findClient(source) == nullptr || source.machine.slot != application.machines_.active() || application.sound_player_.active()) {
    return false;
  }

  application.sound_player_.start(sound);
  application.sound_owner_ = source;

  return true;
}

void ApplicationEffects::notePaneInput(FramePacer::Pane pane, std::uint64_t now_ns) noexcept {
  if (application.findClient(source) != nullptr && source.machine.slot == application.machines_.active() && application.frame_pacer_) {
    application.frame_pacer_->noteInput(pane, now_ns);
  }
}

void Application::soundPlaybackFinished([[maybe_unused]] std::optional<CommandFailure> failure) {
  const auto owner = std::exchange(sound_owner_, std::nullopt);
  auto *client = owner ? findClient(*owner) : nullptr;
  if (client == nullptr) {
    return;
  }

  try {
    client->session.completeAgentSound();
  } catch (const std::exception &error) {
    fail(error);
  }
}

}
