module telar.gui.application;

import std;

import :access;
import telar.gui.features.activity;
import telar.gui.features.notifications;
import telar.gui.foundation.agents;
import telar.gui.foundation.model;
import telar.wire.agents;
import telar.base.ds;

namespace telar::gui::application::activity {

  bool chooseAgent(Session& session, std::uint64_t pane_id, std::uint64_t generation) {
    if (features::activity::find(Access::agents(session).entries(), pane_id, generation) == nullptr) {
      return false;
    }

    workbench::visit(session, pane_id, generation);

    return true;
  }

  bool choosePane(Session& session, std::uint64_t pane_id, std::uint64_t generation) {
    if (Access::paneList(session).find(pane_id, generation) == nullptr) {
      return false;
    }

    workbench::visit(session, pane_id, generation);

    return true;
  }

  void acknowledge(Session& session) {
    if (!session.presented()) {
      return;
    }

    const auto* active = activeTab(session.tabs, session.active_tab);
    if (active == nullptr) {
      return;
    }

    const auto* agent = features::activity::focused(Access::agents(session).entries(), *active);
    const auto focused = agent == nullptr ? ds::none : ds::Option{FocusedAgent{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation, .status = agent->status}};

    if (const auto request = Access::agentAcknowledgement(session).take(focused)) {
      session.link.send(*request);
    }
  }

  Change receive(Session& session, const AgentSnapshot& message) {
    const auto now_ns = Access::now(session);
    auto& agents = Access::agents(session);
    if (!agents.apply(message, now_ns)) {
      return Change::none;
    }

    peek::follow(session);
    acknowledge(session);
    features::notifications::AgentAlerts::publish(agents.statusChanges(), [&](const AgentStatusChange& change) {
      const auto* agent = features::activity::find(agents.entries(), change.pane_id, change.pane_generation);

      return agent == nullptr ? AgentCardLabels::generic_name : AgentCardLabels::title({}, agent->display_name);
    },
        [&](features::notifications::NotificationInput input) {
          notifications::publish(session, input, now_ns);
        });

    return Change::model;
  }

  Change receive(Session& session, const PaneList& message) {
    return Access::paneList(session).apply(message, Access::now(session)) ? Change::model : Change::none;
  }

}
