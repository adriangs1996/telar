#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_effects.hpp"
#include "machine_client.hpp"

import std;
import telar.gui.text.notification_payload;
import telar.gui.platform.awake_clock;
import telar.gui.presentation.frame_pacer;

namespace telar::gui::qt {

  bool MachineEffects::presented() const noexcept {
    return findMachineClient(sinks_.machines, sinks_.clients, source_) != nullptr && source_.machine.slot == sinks_.machines.active();
  }

  bool MachineEffects::postNotification(const NotificationPayload& payload) {
    return presented() && sinks_.desktop.postNotification(payload);
  }

  bool MachineEffects::playSound(AgentSound sound) {
    if (!presented() || !sinks_.desktop.playSound(sound)) {
      return false;
    }

    sinks_.sound_owner = source_;

    return true;
  }

  void MachineEffects::notePaneInput(FramePacer::Pane pane) noexcept {
    if (presented() && sinks_.frame_pacer) {
      sinks_.frame_pacer->noteInput(pane, platform::AwakeClock::nowNanoseconds());
    }
  }

}
