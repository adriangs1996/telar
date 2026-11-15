module telar.gui.application.session;

import std;
import telar.gui.text.notification_payload;

namespace telar::gui {

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

  const PeekScreen<Memory>& Session::peek() const noexcept {
    return peek_;
  }

  const Agent<Memory>* Session::peekAgent() const noexcept {
    if (!peek_.target()) {
      return nullptr;
    }

    return findPeekAgent(*peek_.target());
  }

  bool Session::openPeek(PeekTarget target) {
    if (!ready_ || !presented_ || findPeekAgent(target) == nullptr) {
      return false;
    }

    peek_.show(target);
    try {
      requestPeekScreen();
    } catch (...) {
      peek_.close();
      throw;
    }

    return true;
  }

  void Session::closePeek() noexcept {
    if (peek_.target()) {
      peek_.close();
    }
  }

  bool Session::submitPeek(std::string_view text) {
    const auto* agent = ready_ && presented_ ? peekAgent() : nullptr;
    if (agent == nullptr) {
      closePeek();

      return false;
    }

    if (text.size() > PeekLimits::message_bytes) {
      throw std::length_error{"PeekMessageTooLong"};
    }

    switch (PeekInput::command(text)) {
    case PeekCommand::open:
      static_cast<void>(focusAgent(agent->pane_id, agent->pane_generation));
      break;
    case PeekCommand::stop:
      sendPeekAction(InterruptAgent{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation}, agent->pane_id);
      break;
    case PeekCommand::diff:
      openPeekDiff(*agent);
      break;
    case PeekCommand::message:
      sendPeekAction(SendPaneText{.pane_id = agent->pane_id, .pane_generation = agent->pane_generation, .mode = PaneTextMode::prompt, .text = runtime::trimText(text, " \t"), .sender = {}}, agent->pane_id);
      break;
    }

    closePeek();

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

  const Agent<Memory>* Session::findPeekAgent(const PeekTarget& target) const noexcept {
    const auto found = std::ranges::find_if(agents_, [&](const auto& agent) {
      return agent.pane_id == target.agent.pane_id && agent.pane_generation == target.agent.pane_generation && agent.session_id == target.session;
    });

    return found == agents_.end() ? nullptr : std::addressof(*found);
  }

  void Session::requestPeekScreen() {
    if (!peek_.target() || peek_.reading()) {
      return;
    }

    const auto request_id = pending(RequestKind::peek_screen);

    try {
      if (const auto request = peek_.request(request_id)) {
        send(*request);
      } else {
        complete(request_id);
      }
    } catch (...) {
      peek_.fail(request_id);
      complete(request_id);
      throw;
    }
  }

  void Session::openPeekDiff(const Agent<Memory>& agent) {
    const auto* row = AgentOrder::taskRow(workspaces_, agent);
    if (row == nullptr) {
      return;
    }

    constexpr std::string_view script = R"("$TELAR_BIN_PATH" worktree diff "$1" --stat; echo; "$TELAR_BIN_PATH" worktree diff "$1"; exec "${SHELL:-/bin/sh}")";
    constexpr TerminalSize size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};
    const std::array<std::string_view, 5> arguments{"sh", "-c", script, "sh", row->branch};

    sendPeekAction(LaunchWorktree{.worktree = row->id, .label = "diff", .size = size, .launch = {.cwd = row->path.empty() ? std::string_view{"/"} : std::string_view{row->path}, .arguments = arguments}}, agent.pane_id);
  }

  std::optional<Change> Session::failPeekRequest(const Pending& request, const RequestFailed& failure) {
    if (request.kind == RequestKind::peek_screen) {
      peek_.fail(failure.request_id);

      return Change::none;
    }

    if (request.kind != RequestKind::peek_action && request.kind != RequestKind::peek_diff) {
      return std::nullopt;
    }

    constexpr std::uint64_t duration_ns = 7'000'000'000;

    publishNotification({.level = NotificationLevel::failure, .target = {.kind = NotificationTarget::Kind::pane, .id = request.pane_id}, .title = "The agent did not take it", .message = failure.message, .link = {}, .duration_ns = duration_ns});

    return Change::notification;
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

    if (peek_.target()) {
      if (peekAgent() == nullptr) {
        closePeek();
      } else {
        requestPeekScreen();
      }
    }

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
