#include "application_effects.hpp"
#include "application.hpp"
#include "application/notification_payload.hpp"
#include "command_process.hpp"
#include "presentation/frame_pacer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <exception>
#include <optional>
#include <utility>

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
