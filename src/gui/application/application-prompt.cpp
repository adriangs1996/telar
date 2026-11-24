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
      auto& state = session.prompt;
      if (!session.ready() || !session.configuration.prompt.ghost || features::prompt::historyAsked(state)) {
        return;
      }

      const auto query = features::prompt::historyQuery(session.link.nextRequest());

      if (session.link.offer(query)) {
        features::prompt::askedHistory(state, query.request_id);
      }
    }

    // Whether the runtime has a spec for `command` in `pane`, asking it through `link` the first
    // time: once per command until the shell's next command, with the digest of the spec already
    // held.
    features::prompt::SpecState specState(features::prompt::State& state, Session::Link& link, const Pane<Memory>& pane, std::string_view command) {
      using features::prompt::SpecState;

      if (const auto known = features::prompt::spec(state, commands(pane), command)) {
        return *known;
      }

      const auto request = features::prompt::askSpec(state, pane.id, command, link.nextRequest());

      try {
        link.send(request);
      } catch (const std::exception&) {
        features::prompt::askedSpec(state, pane.id, command, request.request_id, false);
        return SpecState::unavailable;
      }

      features::prompt::askedSpec(state, pane.id, command, request.request_id, true);
      return SpecState::pending;
    }

    // Tab in pane `pane_id`'s line: the spec's literal choices at once, and the runtime's files when
    // the spec, or a command without one, expects a path there.
    void complete(Session& session, std::uint64_t pane_id, shell::Dialect dialect) {
      using features::prompt::SpecState;
      const bool ready = session.ready();
      const auto* pane = findPane(session.panes, pane_id);
      auto* line = features::prompt::find(session.prompt_lines, pane_id);
      if (pane == nullptr || line == nullptr) {
        return;
      }

      auto& state = session.prompt;
      auto context = features::prompt::completing(state, *line, dialect);
      if (!context) {
        return;
      }

      // A command's spec comes from the runtime, for the commands this pane's shell runs; while
      // it is on its way, Tab waits for it and completes once it arrives.
      const bool asks = ready && !pane->shell.remote;
      bool specified = false;

      if (!context->command_position && asks) {
        switch (specState(state, session.link, *pane, context->command)) {
        case SpecState::available:
          specified = true;
          break;
        case SpecState::pending:
          features::prompt::awaitSpec(state, *line);
          return;
        case SpecState::unavailable:
          break;
        }
      }

      auto plan = features::prompt::plan(state, *line, std::move(context.getMut()), {.specified = specified, .asks = asks, .directory = std::string_view{pane->cwd}, .dialect = dialect});

      for (std::size_t index = 0; index < features::prompt::questions(plan); ++index) {
        const auto request_id = session.link.nextRequest();

        const bool queued = std::visit(
            [&](const auto& request) {
              return session.link.offer(request);
            },
            features::prompt::request(plan, {.pane_id = pane_id, .index = index, .request_id = request_id})
        );
        if (queued) {
          features::prompt::sent(plan, index, request_id);
        }
      }

      features::prompt::offer(state, *line, std::move(plan));
    }

    // Sends what pane `pane_id`'s line decided: a command to run, a line for the running program,
    // or raw bytes the shell reads as keys. Commands are validated like a pasted history entry,
    // and the line lets go of one only once it is sent: one that cannot be stays in the editor.
    // The text is copied first: sending it reaches the line again, for a secret prompt's dots.
    void deliver(Session& session, std::uint64_t pane_id, Outcome outcome) {
      const auto* pane = findPane(session.panes, pane_id);
      auto* line = features::prompt::find(session.prompt_lines, pane_id);
      if (pane == nullptr || line == nullptr || !pane->attached || pane->exited) {
        return;
      }

      const bool bracketed = pane->screen.modes().bracketed_paste;
      ds::String<Memory> text{session.memory, features::prompt::delivery(*line)};

      switch (outcome) {
      case Outcome::run:
        features::history::HistoryText::validate(text.view(), bracketed);
        session.runCommand(pane_id, text.view());
        features::prompt::committed(*line, text.view());
        features::prompt::remember(session.prompt, text.view());
        break;
      case Outcome::answer:
        features::history::HistoryText::validate(text.empty() ? std::string_view{" "} : text.view(), false);
        text.push('\r');
        session.input(pane_id, text.view());
        features::prompt::committed(*line, {});
        break;
      case Outcome::bytes:
        session.input(pane_id, text.view());
        break;
      case Outcome::edited:
      case Outcome::terminal:
      case Outcome::ignored:
      case Outcome::complete:
      case Outcome::search_history:
        break;
      }
    }

    // An answer about a command the editor marks: a command found may have a spec, asked now so it
    // is there by the first Tab.
    Change settle(Session& session, const features::prompt::Settled& settled) {
      const auto* pane = findPane(session.panes, settled.pane_id);
      if (pane != nullptr && settled.presence == CommandPresence::found && !settled.word.view().contains('/')) {
        static_cast<void>(specState(session.prompt, session.link, *pane, settled.word.view()));
      }

      return changed(session, features::prompt::settle(session.prompt, settled) ? settled.pane_id : 0);
    }

  }

  Surface surface(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* pane = findPane(session.panes, pane_id);
    const auto mode = session.configuration.prompt.mode;
    // telar's editor stays while copy mode, which owns the keys, reads the scrollback.
    if (pane == nullptr || !pane->attached || pane->exited || (features::terminal::copy_mode::view(session.copy_mode).active() && mode != PromptMode::telar)) {
      return Surface::none;
    }

    return features::prompt::surface(pane->shell, pane->screen.modes().alternate_screen, mode == PromptMode::telar);
  }

  bool edits(const Session& session, std::uint64_t pane_id) noexcept {
    const auto where = surface(session, pane_id);

    return where == Surface::editor || where == Surface::running;
  }

  bool hidesTerminalCursor(const Session& session, std::uint64_t pane_id) noexcept {
    const auto* pane = findPane(session.panes, pane_id);
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
      return session.configuration.prompt.mode == PromptMode::telar && pane->attached && !pane->exited && pane->shell.shell != IntegratedShell::none && pane->shell.phase == ShellPhase::unknown && pane->shell.commands != 0 && !pane->screen.modes().alternate_screen;
    case Surface::editor:
    case Surface::secret:
      break;
    }

    return false;
  }

  ds::Option<LineView> line(const Session& session, std::uint64_t pane_id) noexcept {
    return features::prompt::line(session.prompt, session.prompt_lines, pane_id);
  }

  std::string_view suggestion(const Session& session, std::uint64_t pane_id) noexcept {
    const auto typed = line(session, pane_id);

    return typed ? typed->suggestion() : std::string_view{};
  }

  features::prompt::History history(const Session& session) noexcept {
    return features::prompt::history(session.prompt);
  }

  Outcome key(Session& session, std::uint64_t pane_id, const KeyPress& key) {
    const auto where = surface(session, pane_id);
    if (where != Surface::editor && where != Surface::running) {
      return Outcome::terminal;
    }

    static_cast<void>(open(session, pane_id));

    if (where == Surface::editor) {
      if (const auto outcome = Access::blockKey(session, pane_id, key)) {
        return *outcome;
      }
    }

    const auto* pane = findPane(session.panes, pane_id);
    auto& line = *features::prompt::find(session.prompt_lines, pane_id);
    const auto clock = Access::clock(session);
    const auto now = [clock] {
      return clock();
    };
    if (where == Surface::running && features::prompt::toProgram(line, key, pane->shell, pane->screen.cursor().x, now)) {
      return Outcome::terminal;
    }

    const auto shell = dialect(*pane);
    const auto outcome = features::prompt::press(session.prompt, line, where, key, {.configuration = session.configuration.prompt, .dialect = shell});
    if (outcome == Outcome::complete) {
      complete(session, pane_id, shell);
      return Outcome::edited;
    }

    deliver(session, pane_id, outcome);
    return outcome;
  }

  void text(Session& session, std::uint64_t pane_id, std::string_view text) {
    static_cast<void>(open(session, pane_id));
    features::prompt::insert(session.prompt, *features::prompt::find(session.prompt_lines, pane_id), text);
  }

  CommandPresence commandPresence(Session& session, std::uint64_t pane_id, std::string_view word) {
    const auto* pane = findPane(session.panes, pane_id);
    if (pane == nullptr || pane->shell.remote || !session.ready()) {
      return CommandPresence::unknown;
    }

    auto& state = session.prompt;
    const auto asked = commands(*pane);
    if (const auto known = features::prompt::presence(state, asked, word)) {
      return *known;
    }

    const auto request_id = session.link.nextRequest();

    try {
      const auto query = features::prompt::ask(state.command_root, asked, word, request_id);
      if (!query) {
        return CommandPresence::unknown;
      }

      std::visit(
          [&](const auto& request) {
            session.link.send(request);
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
    return features::prompt::takeWrite(session.prompt);
  }

  features::prompt::PaneLine& open(Session& session, std::uint64_t pane_id) {
    const auto keymap = session.configuration.prompt.keymap == PromptKeymap::vim ? Keymap::vim : Keymap::emacs;
    if (features::prompt::open(session.prompt, session.prompt_lines, pane_id, keymap).wants_history) {
      requestHistory(session);
    }

    return *features::prompt::find(session.prompt_lines, pane_id);
  }

  void write(Session& session, std::uint64_t pane_id, std::string_view command) {
    static_cast<void>(open(session, pane_id));
    features::prompt::write(session.prompt, *features::prompt::find(session.prompt_lines, pane_id), command);
  }

  void typeSecret(Session& session, std::uint64_t pane_id, char byte) {
    features::prompt::typeSecret(open(session, pane_id), byte);
  }

  void follow(Session& session, std::uint64_t pane_id, const PaneShell& previous, const PaneShell& current) {
    auto* line = features::prompt::find(session.prompt_lines, pane_id);
    if (line == nullptr) {
      return;
    }

    if (const auto outcome = features::prompt::follow(*line, previous, current)) {
      deliver(session, pane_id, *outcome);
    }
  }

  void configureShell(Session& session) {
    if (session.readsRows()) {
      session.link.send(ConfigureShellPrompt{.bare = session.configuration.prompt.mode == PromptMode::telar});
    }
  }

  Change receive(Session& session, const CommandSpec& message) {
    auto& state = session.prompt;
    const auto pane_id = features::prompt::receive(state, message);
    if (!pane_id) {
      return Change::none;
    }

    // A Tab that waited for it completes now, if the line is still the one it was for.
    const auto* pane = findPane(session.panes, *pane_id);
    if (pane == nullptr || !features::prompt::resume(state, session.prompt_lines, *pane_id)) {
      return Change::none;
    }

    complete(session, *pane_id, dialect(*pane));
    return changed(session, *pane_id);
  }

  Change receive(Session& session, const CompletionWords& message) {
    if (const auto settled = features::prompt::settles(session.prompt, message)) {
      return settle(session, *settled);
    }

    return changed(session, features::prompt::receive(session.prompt, session.prompt_lines, message).valueOr(0));
  }

  ds::Option<Change> receive(Session& session, const PathResults& message) {
    if (const auto settled = features::prompt::settles(session.prompt, message)) {
      return settle(session, *settled);
    }

    const auto pane_id = features::prompt::receive(session.prompt, session.prompt_lines, message);
    if (!pane_id) {
      return ds::none;
    }

    return changed(session, *pane_id);
  }

  ds::Option<Change> fail(Session& session, std::uint64_t request_id) {
    const auto pane_id = features::prompt::fail(session.prompt, session.prompt_lines, request_id);
    if (!pane_id) {
      return ds::none;
    }

    return changed(session, *pane_id);
  }

}
