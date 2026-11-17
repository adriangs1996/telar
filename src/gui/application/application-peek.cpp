module telar.gui.application;

import std;

import :access;
import telar.base.memory.allocators;
import telar.gui.features.peek;
import telar.gui.foundation.model;
import telar.gui.presentation.activity_order;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.wire.worktrees;

namespace telar::gui::application::peek {

  namespace {

    // Reads the agent's recent screen unless a read is in flight, under a pending request the
    // reply or its failure completes.
    void read(Session& session) {
      auto& state = Access::peek(session);
      if (!features::peek::target(state) || features::peek::reading(state)) {
        return;
      }

      const auto request_id = Access::pending(session, Access::RequestKind::peek_screen);

      try {
        if (const auto request = features::peek::read(state, request_id)) {
          Access::send(session, *request);
        } else {
          Access::complete(session, request_id);
        }
      } catch (...) {
        features::peek::fail(state, request_id);
        Access::complete(session, request_id);
        throw;
      }
    }

    // What an agent's task changed, in a worktree terminal of its own.
    void openDiff(Session& session, const Agent<Memory>& agent) {
      const auto* row = AgentOrder::taskRow(session.workspaceList(), agent);
      if (row == nullptr) {
        return;
      }

      constexpr std::string_view script = R"("$TELAR_BIN_PATH" worktree diff "$1" --stat; echo; "$TELAR_BIN_PATH" worktree diff "$1"; exec "${SHELL:-/bin/sh}")";
      constexpr TerminalSize size{.cols = 160, .rows = 48, .cell_width_px = 0, .cell_height_px = 0};
      const std::array<std::string_view, 5> arguments{"sh", "-c", script, "sh", row->branch};

      Access::sendRegistered(session, Access::RequestKind::peek_diff, LaunchWorktree{.worktree = row->id, .label = "diff", .size = size, .launch = {.cwd = row->path.empty() ? std::string_view{"/"} : std::string_view{row->path}, .arguments = arguments}}, agent.pane_id);
    }

  }

  bool open(Session& session, PeekTarget target) {
    auto& state = Access::peek(session);
    if (!session.ready() || !session.presented() || features::peek::find(session.agents(), target) == nullptr) {
      return false;
    }

    features::peek::open(state, target);
    try {
      read(session);
    } catch (...) {
      features::peek::close(state);
      throw;
    }

    return true;
  }

  void close(Session& session) noexcept {
    auto& state = Access::peek(session);
    if (features::peek::target(state)) {
      features::peek::close(state);
    }
  }

  bool submit(Session& session, std::string_view text) {
    const auto* peeked = session.ready() && session.presented() ? agent(session) : nullptr;
    if (peeked == nullptr) {
      close(session);

      return false;
    }

    const auto submission = features::peek::submit(text);

    switch (submission.command) {
    case features::peek::PeekCommand::open:
      static_cast<void>(session.focusAgent(peeked->pane_id, peeked->pane_generation));
      break;
    case features::peek::PeekCommand::stop:
      Access::sendRegistered(session, Access::RequestKind::peek_action, InterruptAgent{.pane_id = peeked->pane_id, .pane_generation = peeked->pane_generation}, peeked->pane_id);
      break;
    case features::peek::PeekCommand::diff:
      openDiff(session, *peeked);
      break;
    case features::peek::PeekCommand::message:
      Access::sendRegistered(session, Access::RequestKind::peek_action, SendPaneText{.pane_id = peeked->pane_id, .pane_generation = peeked->pane_generation, .mode = PaneTextMode::prompt, .text = submission.message, .sender = {}}, peeked->pane_id);
      break;
    }

    close(session);

    return true;
  }

  const std::optional<PeekTarget>& target(const Session& session) noexcept {
    return features::peek::target(Access::peek(session));
  }

  const Agent<Memory>* agent(const Session& session) noexcept {
    return features::peek::agent(Access::peek(session), session.agents());
  }

  std::string_view text(const Session& session) noexcept {
    return features::peek::text(Access::peek(session));
  }

  std::string_view lines(const Session& session, std::uint16_t rows) noexcept {
    return features::peek::lastLines(text(session), rows);
  }

  bool reading(const Session& session) noexcept {
    return features::peek::reading(Access::peek(session));
  }

  void follow(Session& session) {
    if (!target(session)) {
      return;
    }

    if (agent(session) == nullptr) {
      close(session);
    } else {
      read(session);
    }
  }

  Change receive(Session& session, const PaneText& reply) {
    if (!Access::completeRequest(session, Access::RequestKind::peek_screen, reply.request_id)) {
      return Change::none;
    }

    const auto dropped = features::peek::receive(Access::peek(session), reply);
    if (!dropped) {
      return Change::none;
    }

    if (*dropped != 0) {
      notifications::reportLimit(session, {.name = "peek.text_bytes", .noun = "bytes", .value = PeekLimits::text_bytes, .requested = reply.text.size()});
    }

    return Change::peek;
  }

  void readFailed(Session& session, std::uint64_t request_id) noexcept {
    features::peek::fail(Access::peek(session), request_id);
  }

  Change actionFailed(Session& session, std::uint64_t pane_id, std::string_view message) {
    constexpr std::uint64_t duration_ns = 7'000'000'000;

    notifications::publish(session, {.level = NotificationLevel::failure, .target = {.kind = NotificationTarget::Kind::pane, .id = pane_id}, .title = "The agent did not take it", .message = message, .link = {}, .duration_ns = duration_ns});

    return Change::notification;
  }

}
