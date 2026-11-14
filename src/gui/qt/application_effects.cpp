#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_effects.hpp"
#include "application.hpp"

import std;
import telar.gui.text.notification_payload;
import telar.gui.platform.awake_clock;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

  bool ApplicationEffects::postNotification(const NotificationPayload& payload) {
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

  void ApplicationEffects::notePaneInput(FramePacer::Pane pane) noexcept {
    if (application.findClient(source) != nullptr && source.machine.slot == application.machines_.active() && application.frame_pacer_) {
      application.frame_pacer_->noteInput(pane, platform::AwakeClock::nowNanoseconds());
    }
  }

  void Application::soundPlaybackFinished([[maybe_unused]] std::optional<CommandFailure> failure) {
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
