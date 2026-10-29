#include "application_effects.hpp"
#include "application.hpp"
#include "application/notification_payload.hpp"
#include "command_process.hpp"
#include "presentation/frame_pacer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <exception>
#include <optional>

namespace telar::gui::qt {

bool ApplicationEffects::postNotification(const NotificationPayload &payload) {
  return application.system_notifier_.post(payload);
}

bool ApplicationEffects::playSound(AgentSound sound) {
  application.sound_player_.start(sound);

  return true;
}

void ApplicationEffects::notePaneInput(FramePacer::Pane pane, std::uint64_t now_ns) noexcept {
  if (application.frame_pacer_) {
    application.frame_pacer_->noteInput(pane, now_ns);
  }
}

void Application::soundPlaybackFinished([[maybe_unused]] std::optional<CommandFailure> failure) {
  try {
    session_.completeAgentSound();
  } catch (const std::exception &error) {
    fail(error);
  }
}

}
