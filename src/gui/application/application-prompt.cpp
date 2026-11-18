module telar.gui.application;

import std;

import :access;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.gui.features.terminal.copy_mode;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.shell.syntax;
import telar.wire.editor;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application::prompt {

  namespace {

    shell::Dialect dialect(const Pane<Memory>& pane) noexcept {
      return pane.shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix;
    }

    features::prompt::Commands commands(const Pane<Memory>& pane) noexcept {
      return {.pane_id = pane.id, .commands = pane.shell.commands, .directory = std::string_view{pane.cwd}};
    }

    // Pane `pane_id`'s line changed when it is not 0, for its view to redraw.
    Change changed(Session& session, std::uint64_t pane_id) noexcept {
      if (pane_id == 0) {
        return Change::none;
      }

      Access::changedPane(session) = pane_id;
      return Change::terminal;
    }

    // The commands people typed, most recent first and each once, for the editor's suggestions.
    void requestHistory(Session& session) {
      auto& state = Access::prompt(session);
      if (!session.ready() || !session.configuration().prompt.ghost || features::prompt::historyAsked(state)) {
        return;
      }

      const auto query = features::prompt::historyQuery(Access::nextRequest(session));

      try {
        Access::send(session, query);
        features::prompt::askedHistory(state, query.request_id);
      } catch (const std::length_error&) {
      }
    }

    // Whether the runtime has a spec for `command` in pane `pane_id`, asking it the first time:
    // once per command until the shell's next command, with the digest of the spec already held.
    features::prompt::SpecState specState(Session& session, std::uint64_t pane_id, std::string_view command) {
      using features::prompt::SpecState;
      const auto* pane = session.findPane(pane_id);
      if (pane == nullptr) {
        return SpecState::unavailable;
      }

      auto& state = Access::prompt(session);
      if (const auto known = features::prompt::spec(state, commands(*pane), command)) {
        return *known;
      }

      const auto request = features::prompt::askSpec(state, pane_id, command, Access::nextRequest(session));

      try {
        Access::send(session, request);
      } catch (const std::exception&) {
        features::prompt::askedSpec(state, pane_id, command, request.request_id, false);
        return SpecState::unavailable;
      }

      features::prompt::askedSpec(state, pane_id, command, request.request_id, true);
      return SpecState::pending;
    }

    // Tab: the spec's literal choices at once, and the runtime's files when the spec, or a
    // command without one, expects a path there.
    void complete(Session& session, std::uint64_t pane_id, features::prompt::PaneLine& line, shell::Dialect dialect) {
      using features::prompt::SpecState;
      const auto* pane = session.findPane(pane_id);
      auto context = features::prompt::completing(line, dialect);
      if (pane == nullptr || !context) {
        return;
      }

      // A command's spec comes from the runtime, for the commands this pane's shell runs; while
      // it is on its way, Tab waits for it and completes once it arrives.
      auto& state = Access::prompt(session);
      bool specified = false;

      if (!context->command_position && !pane->shell.remote && session.ready()) {
        switch (specState(session, pane_id, context->command)) {
        case SpecState::available:
          specified = true;
          break;
        case SpecState::pending:
          features::prompt::awaitSpec(state, line);
          return;
        case SpecState::unavailable:
          break;
        }
      }

      auto plan = features::prompt::plan(state, line, std::move(context.getMut()), specified, session.ready() && !pane->shell.remote, std::string_view{pane->cwd}, dialect);

      for (std::size_t index = 0; index < features::prompt::questions(plan); ++index) {
        const auto request_id = Access::nextRequest(session);

        try {
          std::visit(
              [&](const auto& request) {
                Access::send(session, request);
              },
              features::prompt::request(plan, index, pane_id, request_id)
          );
          features::prompt::sent(plan, index, request_id);
        } catch (const std::length_error&) {
        }
      }

      features::prompt::offer(state, line, std::move(plan));
    }

    // Sends what the editor decided: a command to run, a line for the running program, or raw
    // bytes the shell reads as keys. Commands are validated like a pasted history entry.
    void deliver(Session& session, std::uint64_t pane_id, Outcome outcome, const features::prompt::PaneLine& line) {
      const auto* pane = session.findPane(pane_id);
      if (pane == nullptr || !pane->attached || pane->exited) {
        return;
      }

      const auto text = features::prompt::delivery(line);

      switch (outcome) {
      case Outcome::run:
        features::history::HistoryText::validate(text, pane->screen.modes().bracketed_paste);
        session.runCommand(pane_id, text);
        features::prompt::remember(Access::prompt(session), text);
        break;
      case Outcome::answer: {
        features::history::HistoryText::validate(text.empty() ? std::string_view{" "} : text, false);
        std::string answer{text};

        answer.push_back('\r');
        session.input(pane_id, answer);
        break;
      }
      case Outcome::bytes:
        session.input(pane_id, text);
        break;
      default:
        break;
      }
    }

    // An answer about a command the editor marks: a command found may have a spec, asked now so it
    // is there by the first Tab.
    Change settle(Session& session, const features::prompt::Settled& settled) {
      if (settled.presence == CommandPresence::found && settled.word.find('/') == std::string::npos) {
        static_cast<void>(specState(session, settled.pane_id, settled.word));
      }

      return changed(session, features::prompt::settle(Access::prompt(session), settled) ? settled.pane_id : 0);
    }

  }

  Surface surface(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* pane = session.findPane(pane_id);
    const auto mode = session.configuration().prompt.mode;
    // telar's editor stays while copy mode, which owns the keys, reads the scrollback.
    if (pane == nullptr || !pane->attached || pane->exited || (features::terminal::copy_mode::view(Access::copyMode(session)).active() && mode != PromptMode::telar)) {
      return Surface::none;
    }

    return features::prompt::surface(pane->shell, pane->screen.modes().alternate_screen, mode == PromptMode::telar);
  }

  bool edits(const Session& session, std::uint64_t pane_id) noexcept {
    const auto where = surface(session, pane_id);

    return where == Surface::editor || where == Surface::running;
  }

  bool hidesTerminalCursor(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* pane = session.findPane(pane_id);
    if (pane == nullptr) {
      return false;
    }

    const auto where = surface(session, pane_id);
    // At the prompt every key goes to telar's editor, whatever frame the terminal still shows.
    if (where == Surface::editor) {
      return true;
    }

    if (pane->screen.cursor().x != 0) {
      return false;
    }

    switch (where) {
    case Surface::running: {
      const auto typed = line(session, pane_id);

      return !typed || !typed->answering();
    }
    case Surface::none:
      return session.configuration().prompt.mode == PromptMode::telar && pane->attached && !pane->exited && pane->shell.shell != IntegratedShell::none && pane->shell.phase == ShellPhase::unknown && pane->shell.commands != 0 && !pane->screen.modes().alternate_screen;
    case Surface::editor:
    case Surface::secret:
      break;
    }

    return false;
  }

  ds::Option<LineView> line(const Session& session, std::uint64_t pane_id) noexcept {
    return features::prompt::line(Access::prompt(session), pane_id);
  }

  std::string_view suggestion(const Session& session, std::uint64_t pane_id) noexcept {
    const auto typed = line(session, pane_id);

    return typed ? typed->suggestion() : std::string_view{};
  }

  std::span<const std::string> history(const Session& session) noexcept {
    return features::prompt::history(Access::prompt(session));
  }

  Outcome key(Session& session, std::uint64_t pane_id, const KeyPress& key) {
    const auto where = surface(session, pane_id);
    if (where != Surface::editor && where != Surface::running) {
      return Outcome::terminal;
    }

    auto& line = open(session, pane_id);

    if (where == Surface::editor) {
      if (const auto outcome = Access::blockKey(session, pane_id, line, key)) {
        return *outcome;
      }
    }

    const auto* pane = session.findPane(pane_id);
    const auto now = [&session] {
      return Access::now(session);
    };
    if (where == Surface::running && features::prompt::toProgram(line, key, pane->shell, pane->screen.cursor().x, now)) {
      return Outcome::terminal;
    }

    const auto shell = dialect(*pane);
    const auto outcome = features::prompt::press(Access::prompt(session), line, where, key, session.configuration().prompt, shell);
    if (outcome == Outcome::complete) {
      complete(session, pane_id, line, shell);
      return Outcome::edited;
    }

    deliver(session, pane_id, outcome, line);
    return outcome;
  }

  void text(Session& session, std::uint64_t pane_id, std::string_view text) {
    features::prompt::insert(Access::prompt(session), open(session, pane_id), text);
  }

  CommandPresence commandPresence(Session& session, std::uint64_t pane_id, std::string_view word) {
    const auto* pane = session.findPane(pane_id);
    if (pane == nullptr || pane->shell.remote || !session.ready()) {
      return CommandPresence::unknown;
    }

    auto& state = Access::prompt(session);
    const auto asked = commands(*pane);
    if (const auto known = features::prompt::presence(state, asked, word)) {
      return *known;
    }

    const auto request_id = Access::nextRequest(session);

    try {
      const auto query = features::prompt::ask(state, asked, word, request_id);
      if (!query) {
        return CommandPresence::unknown;
      }

      std::visit(
          [&](const auto& request) {
            Access::send(session, request);
          },
          *query
      );
    } catch (const std::exception&) {
      features::prompt::asked(state, pane_id, word, request_id, false);
      return CommandPresence::unknown;
    }

    features::prompt::asked(state, pane_id, word, request_id, true);
    return CommandPresence::pending;
  }

  ds::Option<std::uint64_t> takeWrite(Session& session) noexcept {
    return features::prompt::takeWrite(Access::prompt(session));
  }

  features::prompt::PaneLine& open(Session& session, std::uint64_t pane_id) {
    const auto keymap = session.configuration().prompt.keymap == PromptKeymap::vim ? Keymap::vim : Keymap::emacs;
    const auto opened = features::prompt::open(Access::prompt(session), pane_id, keymap);
    if (opened.wants_history) {
      requestHistory(session);
    }

    return opened.line;
  }

  void write(Session& session, std::uint64_t pane_id, std::string_view command) {
    features::prompt::write(Access::prompt(session), open(session, pane_id), command);
  }

  void typeSecret(Session& session, std::uint64_t pane_id, char byte) {
    features::prompt::typeSecret(open(session, pane_id), byte);
  }

  void follow(Session& session, std::uint64_t pane_id, const PaneShell& previous, const PaneShell& current) {
    auto* line = features::prompt::find(Access::prompt(session), pane_id);
    if (line == nullptr) {
      return;
    }

    if (const auto outcome = features::prompt::follow(*line, previous, current)) {
      deliver(session, pane_id, *outcome, *line);
    }
  }

  void configureShell(Session& session) {
    if (session.readsRows()) {
      Access::send(session, ConfigureShellPrompt{.bare = session.configuration().prompt.mode == PromptMode::telar});
    }
  }

  Change receive(Session& session, const CommandSpec& message) {
    auto& state = Access::prompt(session);
    const auto pane_id = features::prompt::receive(state, message);
    if (!pane_id) {
      return Change::none;
    }

    // A Tab that waited for it completes now, if the line is still the one it was for.
    const auto* pane = session.findPane(*pane_id);
    if (pane == nullptr || !features::prompt::resume(state, *pane_id)) {
      return Change::none;
    }

    complete(session, *pane_id, *features::prompt::find(state, *pane_id), dialect(*pane));
    return changed(session, *pane_id);
  }

  Change receive(Session& session, const CompletionWords& message) {
    if (const auto settled = features::prompt::settles(Access::prompt(session), message)) {
      return settle(session, *settled);
    }

    return changed(session, features::prompt::receive(Access::prompt(session), message).valueOr(0));
  }

  ds::Option<Change> receive(Session& session, const PathResults& message) {
    if (const auto settled = features::prompt::settles(Access::prompt(session), message)) {
      return settle(session, *settled);
    }

    const auto pane_id = features::prompt::receive(Access::prompt(session), message);
    if (!pane_id) {
      return ds::none;
    }

    return changed(session, *pane_id);
  }

  ds::Option<Change> fail(Session& session, std::uint64_t request_id) {
    const auto pane_id = features::prompt::fail(Access::prompt(session), request_id);
    if (!pane_id) {
      return ds::none;
    }

    return changed(session, *pane_id);
  }

}
