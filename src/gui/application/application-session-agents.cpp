module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.features.activity;
import telar.config.client;
import telar.base.text;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.wire.vocabulary;

namespace telar::gui::application {

  void Session::visitPane(std::uint64_t pane_id, std::optional<std::uint64_t> generation) {
    if (!ready_ || !presented_) {
      return;
    }

    const auto* pane = findPane(pane_id);
    if (pane != nullptr && (!generation || pane->generation == *generation) && active_tab_ && sameWorkspace(pane->location.workspace, active_tab_->workspace)) {
      focusPane(pane_id);
    } else if (!requestsPending()) {
      handoffPane(pane_id, features::activity::workspaceOf(agents_.entries(), pane_list_.entries(), pane_id, generation));
    }
  }

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
