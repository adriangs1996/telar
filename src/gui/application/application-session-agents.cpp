module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.config.client;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.pane_io;

namespace telar::gui::application {

  Change Session::apply(const AgentSnapshot& message) {
    return activity::receive(*this, message);
  }

  Change Session::apply(const PaneList& message) {
    return activity::receive(*this, message);
  }

  Change Session::apply(const Notification& message) {
    return notifications::receive(*this, message);
  }

  Change Session::apply(const AgentSoundNotification& message) {
    return notifications::receive(*this, message);
  }

}
