module telar.gui.ui.app;

import std;
import telar.gui.foundation.system;

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

}
