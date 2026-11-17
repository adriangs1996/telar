module telar.gui.application;

import std;
import telar.gui.features.notifications;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.presentation.application_mark;
import telar.config.client;
import telar.config.runtime;
import telar.base.text;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.shell.syntax;

namespace telar::gui::application {

  void Session::visitPane(std::uint64_t pane_id, std::optional<std::uint64_t> generation) {
    if (!ready_ || !presented_) {
      return;
    }

    const auto* pane = findPane(pane_id);
    if (pane != nullptr && (!generation || pane->generation == *generation) && active_tab_ && sameWorkspace(pane->location.workspace, active_tab_->workspace)) {
      focusPane(pane_id);
    } else if (!requestsPending()) {
      const auto agent = std::ranges::find_if(agents_, [&](const auto& entry) {
        return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
      });

      const auto listed = std::ranges::find_if(pane_list_.entries(), [&](const auto& entry) {
        return entry.pane_id == pane_id && (!generation || entry.pane_generation == *generation);
      });

      const auto location = agent != agents_.end() ? std::optional{agent->location} : listed != pane_list_.entries().end() ? std::optional{listed->location}
                                                                                                                           : std::nullopt;
      const auto fallback = location && location->workspace.kind == WorkspaceLocation::Kind::workspace ? std::optional{location->workspace.id} : std::nullopt;

      handoffPane(pane_id, fallback);
    }
  }

  bool Session::focusAgent(std::uint64_t pane_id, std::uint64_t generation) {
    const auto agent = std::ranges::find_if(agents_.entries(), [&](const auto& entry) {
      return entry.pane_id == pane_id && entry.pane_generation == generation;
    });
    if (agent == agents_.entries().end()) {
      return false;
    }

    visitPane(pane_id, generation);

    return true;
  }

  bool Session::focusListedPane(std::uint64_t pane_id, std::uint64_t generation) {
    if (pane_list_.find(pane_id, generation) == nullptr) {
      return false;
    }

    visitPane(pane_id, generation);

    return true;
  }

  void Session::acknowledgeFocusedAgent() {
    if (!presented_) {
      return;
    }

    const auto* active = activeTab();
    if (active == nullptr) {
      return;
    }

    const auto agent = std::ranges::find_if(agents_, [&](const auto& candidate) {
      return candidate.pane_id == active->focused_pane && sameTab(candidate.location, active->location);
    });

    const auto focused = agent == agents_.end() ? std::nullopt : std::optional{FocusedAgent{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation, .status = agent->status}};

    if (const auto request = agent_acknowledgement_.take(focused)) {
      send(*request);
    }
  }

  Change Session::apply(const AgentSnapshot& message) {
    const auto now_ns = now_();
    if (!agents_.apply(message, now_ns)) {
      return Change::none;
    }

    peek::follow(*this);
    acknowledgeFocusedAgent();
    features::notifications::AgentAlerts::publish(agents_.statusChanges(), [&](const AgentStatusChange& change) {
      const auto agent = std::ranges::find_if(agents_, [&](const auto& candidate) {
        return candidate.pane_id == change.pane_id && candidate.pane_generation == change.pane_generation;
      });

      return agent == agents_.end() ? AgentCardLabels::generic_name : AgentCardLabels::title({}, agent->display_name);
    },
        [&](features::notifications::NotificationInput input) {
          notifications::publish(*this, input, now_ns);
        });

    return Change::model;
  }

  Change Session::apply(const PaneList& message) {
    return pane_list_.apply(message, now_()) ? Change::model : Change::none;
  }

  Change Session::apply(const Notification& message) {
    return notifications::receive(*this, message);
  }

  Change Session::apply(const AgentSoundNotification& message) {
    return notifications::receive(*this, message);
  }

}
