#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_effects.hpp"
#include "application_controller.hpp"

import std;
import telar.gui.text.notification_payload;

namespace telar::gui::qt {

  bool ApplicationEffects::postNotification(const NotificationPayload& payload) {
    return notifier.post(payload);
  }

  bool ApplicationEffects::playSound(AgentSound sound) {
    if (player.active()) {
      return false;
    }

    player.start(sound);

    return true;
  }

  void ApplicationController::soundPlaybackFinished([[maybe_unused]] std::optional<CommandFailure> failure) {
    const auto owner = std::exchange(sound_owner_, std::nullopt);
    auto* client = owner ? findClient(*owner) : nullptr;
    if (client == nullptr) {
      return;
    }

    try {
      client->session.completeAgentSound();
    } catch (const std::exception& error) {
      fail(error);
    }
  }

}
