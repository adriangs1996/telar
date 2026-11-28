module telar.gui.ui.kit.machines;

import std;
import telar.gui.foundation.system;
import telar.gui.application;

namespace telar::gui::qt {

  bool MachineEffects::postNotification(const NotificationPayload& payload) {
    return presented_ && sinks_.desktop.postNotification(payload);
  }

  bool MachineEffects::playSound(AgentSound sound) {
    if (!presented_ || !sinks_.desktop.playSound(sound)) {
      return false;
    }

    sinks_.sound_owner.set(source_);

    return true;
  }

  void MachineEffects::notePaneInput(application::window::FramePacer::Pane pane) noexcept {
    if (presented_ && sinks_.frame_pacer) {
      sinks_.frame_pacer.getMut().noteInput(pane, system::AwakeClock::nowNanoseconds());
    }
  }

}
