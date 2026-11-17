module telar.gui.application;

import std;
import telar.gui.foundation.agents;
import telar.gui.text.notification_payload;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.tbc;
import telar.gui.presentation.application_mark;
import telar.config.client;
import telar.config.runtime;
import telar.base.diagnostics;
import telar.base.text;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.gui.presentation.notification_center;
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

  void Session::publishNotification(NotificationInput input) {
    publishNotificationAt(input, now_());
  }

  void Session::reportLimit(LimitReach reach) {
    const auto recorded = countLimitReach(reach);
    if (recorded.show) {
      const auto& row = limit_reports_.row(recorded.slot);
      const auto message = LimitReports::describe(row.reach(), row.hits);

      publishNotification({.level = NotificationLevel::warning, .title = "Limit reached", .message = message.view(), .link = {}, .duration_ns = limit_notice_duration_ns});
    }
  }

  void Session::completeAgentSound() {
    if (const auto next = sound_playback_.complete()) {
      startAgentSound(*next);
    }
  }

  bool Session::advanceNotifications(std::uint64_t now_ns) noexcept {
    if (!notifications_.advance(now_ns)) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  bool Session::dismissNotification(NotificationId id) noexcept {
    if (!notifications_.dismiss(id, now_())) {
      return false;
    }

    ++notification_revision_;

    return true;
  }

  bool Session::activateNotification(NotificationId id) {
    const auto target = notifications_.activate(id, now_());
    if (!target) {
      return false;
    }

    ++notification_revision_;
    switch (target->kind) {
    case NotificationTarget::Kind::pane:
      focusPane(target->id);
      break;
    case NotificationTarget::Kind::tab: {
      const auto tab = std::ranges::find_if(tabs_, [&](const auto& candidate) {
        return candidate->location.tab_id == target->id;
      });
      if (tab != tabs_.end()) {
        selectTab((*tab)->location);
      }
    } break;
    case NotificationTarget::Kind::workspace:
      selectWorkspace({.kind = WorkspaceLocation::Kind::workspace, .id = target->id});
      break;
    case NotificationTarget::Kind::none:
      break;
    }

    return true;
  }

  bool Session::notificationTargetVisible(NotificationTarget target) const noexcept {
    const auto* tab = activeTab();

    return target.kind == NotificationTarget::Kind::pane && tab != nullptr && tab->layout.contains(target.id);
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
    AgentAlerts::publish(agents_.statusChanges(), [&](const AgentStatusChange& change) {
      const auto agent = std::ranges::find_if(agents_, [&](const auto& candidate) {
        return candidate.pane_id == change.pane_id && candidate.pane_generation == change.pane_generation;
      });

      return agent == agents_.end() ? AgentCardLabels::generic_name : AgentCardLabels::title({}, agent->display_name);
    },
        [&](NotificationInput input) {
          publishNotificationAt(input, now_ns);
        });

    return Change::model;
  }

  Change Session::apply(const PaneList& message) {
    return pane_list_.apply(message, now_()) ? Change::model : Change::none;
  }

  Change Session::apply(const Notification& message) {
    publishNotification({.level = message.level, .target = message.target, .title = message.title, .message = message.message, .link = message.link, .duration_ns = static_cast<std::uint64_t>(message.duration_ms) * NotificationInput::nanoseconds_per_millisecond});

    return Change::notification;
  }

  void Session::publishNotificationAt(NotificationInput input, std::uint64_t now_ns) {
    notifications_.push(now_ns, input);
    ++notification_revision_;

    static_cast<void>(deliverHostNotification(input));
  }

  bool Session::deliverHostNotification(const NotificationInput& input) noexcept {
    if (configuration_.notification_delivery != NotificationDelivery::system) {
      return false;
    }

    try {
      return effects_.postNotification(NotificationPayload::create(input.title, input.message));
    } catch (...) {
      return false;
    }
  }

  Change Session::apply(const AgentSoundNotification& message) {
    const auto current = std::ranges::any_of(agents_, [&](const auto& agent) {
      return agent.pane_id == message.pane_id && agent.pane_generation == message.pane_generation;
    });
    if (current) {
      const auto outcome = sound_playback_.request(message.sound);
      if (outcome.state == SoundRequestOutcome::State::start) {
        startAgentSound(outcome.sound);
      }
    }

    return Change::none;
  }

  void Session::startAgentSound(AgentSound sound) {
    try {
      if (!effects_.playSound(sound)) {
        sound_playback_.schedulingFailed();
      }
    } catch (...) {
      sound_playback_.schedulingFailed();
      throw;
    }
  }

}
