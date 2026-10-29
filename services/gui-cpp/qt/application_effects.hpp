#pragma once

#include "application/notification_payload.hpp"
#include "machine_client_key.hpp"
#include "presentation/frame_pacer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>

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
