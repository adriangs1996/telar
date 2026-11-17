module telar.gui.application;

import std;

import :access;
import telar.base.diagnostics;
import telar.gui.features.notifications;
import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.platform.events;
import telar.wire.agents;
import telar.wire.vocabulary;

namespace telar::gui::application::notifications {

  namespace {

    namespace feature = features::notifications;

    bool deliverHostNotification(Session& session, const NotificationInput& input) noexcept {
      if (Access::configuration(std::as_const(session)).notification_delivery != NotificationDelivery::system) {
        return false;
      }

      try {
        return Access::effects(session).postNotification(NotificationPayload::create(input.title, input.message));
      } catch (...) {
        return false;
      }
    }

    void startSound(Session& session, AgentSound sound) {
      auto& state = Access::notifications(session);

      try {
        if (!Access::effects(session).playSound(sound)) {
          feature::soundFailed(state);
        }
      } catch (...) {
        feature::soundFailed(state);
        throw;
      }
    }

  }

  const NotificationCenter& center(const Session& session) noexcept {
    return feature::center(Access::notifications(session));
  }

  std::uint64_t revision(const Session& session) noexcept {
    return feature::revision(Access::notifications(session));
  }

  void publish(Session& session, NotificationInput input) {
    publish(session, input, Access::now(session));
  }

  void publish(Session& session, NotificationInput input, std::uint64_t now_ns) {
    feature::publish(Access::notifications(session), input, now_ns);

    static_cast<void>(deliverHostNotification(session, input));
  }

  bool advance(Session& session, std::uint64_t now_ns) noexcept {
    return feature::advance(Access::notifications(session), now_ns);
  }

  bool dismiss(Session& session, NotificationId id) noexcept {
    return feature::dismiss(Access::notifications(session), id, Access::now(session));
  }

  bool activate(Session& session, NotificationId id) {
    const auto target = feature::activate(Access::notifications(session), id, Access::now(session));
    if (!target) {
      return false;
    }

    switch (target->kind) {
    case NotificationTarget::Kind::pane:
      workbench::focusPane(session, target->id);
      break;
    case NotificationTarget::Kind::tab: {
      const auto& tabs = session.tabs();
      const auto tab = std::ranges::find_if(tabs, [&](const auto& candidate) {
        return candidate->location.tab_id == target->id;
      });
      if (tab != tabs.end()) {
        workbench::selectTab(session, (*tab)->location);
      }
    } break;
    case NotificationTarget::Kind::workspace:
      workbench::selectWorkspace(session, {.kind = WorkspaceLocation::Kind::workspace, .id = target->id});
      break;
    case NotificationTarget::Kind::none:
      break;
    }

    return true;
  }

  bool targetVisible(const Session& session, NotificationTarget target) noexcept {
    const auto* tab = session.activeTab();

    return target.kind == NotificationTarget::Kind::pane && tab != nullptr && tab->layout.contains(target.id);
  }

  feature::LimitRecorded countLimitReach(Session& session, LimitReach reach) {
    auto& state = Access::notifications(session);
    const auto awake_ms = static_cast<std::int64_t>(Access::now(session) / NotificationInput::nanoseconds_per_millisecond);
    const feature::LimitTime sampled{.awake_ms = awake_ms, .real_ms = runtime::ObservationTime::now().milliseconds};
    const auto recorded = feature::record(state, reach, sampled);
    if (const auto report = feature::takeReport(state, recorded.slot, awake_ms)) {
      bool delivered = false;

      try {
        delivered = Access::report(session, *report);
      } catch (const std::exception&) {
        delivered = false;
      }

      if (!delivered) {
        feature::restoreReport(state, recorded.slot, report->hits);
      }
    }

    return recorded;
  }

  feature::LimitNotices::Description describeLimit(const Session& session, feature::LimitSlot slot) {
    return feature::describe(Access::notifications(session), slot);
  }

  void reportLimit(Session& session, LimitReach reach) {
    const auto recorded = countLimitReach(session, reach);
    if (recorded.show) {
      const auto message = describeLimit(session, recorded.slot);

      publish(session, {.level = NotificationLevel::warning, .title = "Limit reached", .message = message.view(), .link = {}, .duration_ns = feature::LimitNotices::duration_ns});
    }
  }

  void completeSound(Session& session) {
    if (const auto next = feature::completeSound(Access::notifications(session))) {
      startSound(session, *next);
    }
  }

  Change receive(Session& session, const Notification& message) {
    publish(session, {.level = message.level, .target = message.target, .title = message.title, .message = message.message, .link = message.link, .duration_ns = static_cast<std::uint64_t>(message.duration_ms) * NotificationInput::nanoseconds_per_millisecond});

    return Change::notification;
  }

  Change receive(Session& session, const AgentSoundNotification& message) {
    const auto& agents = session.agents();
    const auto current = std::ranges::any_of(agents, [&](const auto& agent) {
      return agent.pane_id == message.pane_id && agent.pane_generation == message.pane_generation;
    });
    if (current) {
      const auto outcome = feature::requestSound(Access::notifications(session), message.sound);
      if (outcome.state == feature::SoundRequestOutcome::State::start) {
        startSound(session, outcome.sound);
      }
    }

    return Change::none;
  }

}
