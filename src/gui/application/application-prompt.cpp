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
import telar.wire.history;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.client;
import telar.tbc;

namespace telar::gui::application::prompt {

  namespace {

    shell::Dialect dialect(const Pane<Memory>& pane) noexcept {
      return pane.shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix;
    }

    features::prompt::Commands commands(const Pane<Memory>& pane) noexcept {
      return {.pane_id = pane.id, .commands = pane.shell.commands, .directory = std::string_view{pane.cwd}};
    }

    // The end of what `pane`'s program printed before its cursor on its row, for the routing to
    // read a question in: its last cells that fit PendingPrompt::read_bytes.
    struct Asked {
      ds::Array<char, features::prompt::PendingPrompt::read_bytes> bytes{};
      std::size_t size = 0;

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes.data(), size};
      }
    };

    Asked asked(const Pane<Memory>& pane) noexcept {
      const auto& screen = pane.screen;
      const auto cells = screen.row(screen.cursor().y);
      const auto end = std::min<std::size_t>(screen.cursor().x, cells.size());
      auto start = end;
      std::size_t taken = 0;
      Asked result;

      while (start > 0 && taken + cells[start - 1].utf8().size() <= result.bytes.size()) {
        taken += cells[--start].utf8().size();
      }

      for (const auto& cell : cells.subspan(start, end - start)) {
        const auto text = cell.utf8();

        std::ranges::copy(text, result.bytes.viewMut().begin() + static_cast<std::ptrdiff_t>(result.size));
        result.size += text.size();
      }

      return result;
    }

    // Where `pane`'s line runs, for the suggestions and Up to rank commands by: its directory and
    // its workspace's path, as the history records them.
    tbc::val_a<features::prompt::Place> place(tbc::ref_a<Session> session, tbc::ref_a<Pane<Memory>> pane) noexcept {
      const auto& workspaces = session.workspace_list.entries();
      const auto* const workspace = std::ranges::find_if(workspaces, [&pane](const auto& entry) {
        return entry.location.kind == WorkspaceLocation::Kind::workspace && sameWorkspace(entry.location, pane.location.workspace);
      });

      return {.pane_id = pane.id, .directory = std::string_view{pane.cwd}, .workspace = workspace == workspaces.end() ? std::string_view{} : std::string_view{workspace->path}};
    }

    tbc::val_a<features::prompt::Place> place(tbc::ref_a<Session> session, std::uint64_t pane_id) noexcept {
      const auto* pane = findPane(session.panes, pane_id);

      return pane == nullptr ? features::prompt::Place{.pane_id = pane_id} : place(session, *pane);
    }

    // The shell of a pane in telar's mode reported a command's end and is not back at its prompt
    // yet: it runs its hooks, and the line is about to take the row.
    bool afterCommand(const Session& session, const Pane<Memory>& pane) noexcept {
      return session.configuration.prompt.mode == PromptMode::telar && pane.attached && !pane.exited && pane.shell.shell != IntegratedShell::none && pane.shell.phase == ShellPhase::unknown && pane.shell.commands != 0 && !pane.screen.modes().alternate_screen;
    }

    // Keys typed now in pane `pane_id` wait in its line for the prompt (BetweenCommands).
    bool betweenCommands(const Session& session, std::uint64_t pane_id) noexcept {
      const auto* pane = findPane(session.panes, pane_id);
      const auto* line = session.prompt_lines.find(pane_id);

      return pane != nullptr && line != nullptr && afterCommand(session, *pane) && features::prompt::BetweenCommands::now(**line, static_cast<std::int64_t>(Access::clock(session)()));
    }

    // Pane `pane_id`'s line changed when it is not 0, for its view to redraw.
    Change changed(Session& session, std::uint64_t pane_id) noexcept {
      if (pane_id == 0) {
        return Change::none;
      }

      Access::changedPane(session) = pane_id;
      return Change::terminal;
    }

    // The commands people typed, most recent first and each once, for the editor's suggestions and
    // for Up, which reads them whether or not suggestions show.
    void requestHistory(Session& session) {
      if (!session.ready() || features::prompt::historyAsked(session.prompt)) {
        return;
      }

      const auto query = features::prompt::historyQuery(session.link.nextRequest());

      if (session.link.offer(query)) {
        features::prompt::askedHistory(session.prompt, query.request_id);
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
      const bool reads_directories = session.speaks(handshake::directory_words);
      const bool reads_references = session.speaks(handshake::reference_words);
      const bool reads_shell = session.speaks(handshake::shell_words);
      const bool reads_remote = session.speaks(handshake::remote_words);
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

      // A command's spec comes from the runtime, for the commands this pane's shell runs, a remote
      // one's too; while it is on its way, Tab waits for it and completes once it arrives. Files,
      // commands and providers for a shell on this host; a shell `ssh` reached has its files and
      // its shell's words from its host, from a runtime that asks it.
      const bool remote = pane->shell.remote;
      const bool asks = ready && (!remote || reads_remote);
      bool specified = false;

      if (!context->command_position && ready) {
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

      auto plan = features::prompt::plan(state, *line, std::move(context.getMut()), {.specified = specified, .asks = asks, .directory = std::string_view{pane->cwd}, .dialect = dialect, .reads_directories = reads_directories, .reads_references = reads_references, .reads_shell = reads_shell, .remote = remote});

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

    // An answer the line took narrowed nothing it could trust: Tab asks again for the word.
    void askAgain(Session& session, std::uint64_t pane_id) {
      const auto* pane = findPane(session.panes, pane_id);
      if (pane != nullptr && features::prompt::asksAgain(session.prompt_lines, pane_id)) {
        complete(session, pane_id, dialect(*pane));
      }
    }

    // Sends what pane `pane_id`'s line decided: a command to run, a line for the running program,
    // or raw bytes the shell reads as keys. Commands are validated like a pasted history entry,
    // and the line lets go of one only once it is sent: one that cannot be stays in the editor.
    // A runtime that answers a command has the line clear at once, as the shell's would, and
    // nothing remember it until it says it typed it: one it refuses comes back (refused).
    // The text is copied first: sending it reaches the line again, for a secret prompt's dots.
    void deliver(Session& session, std::uint64_t pane_id, Outcome outcome) {
      const auto* pane = findPane(session.panes, pane_id);
      const auto* line = features::prompt::find(session.prompt_lines, pane_id);
      if (pane == nullptr || line == nullptr || !pane->attached || pane->exited) {
        return;
      }

      const bool bracketed = pane->screen.modes().bracketed_paste;
      const ds::String<Memory> text{session.memory, features::prompt::delivery(*line)};

      switch (outcome) {
      case Outcome::run: {
        // At the shell's prompt a line break typed without bracketed paste is Enter, which runs
        // each line in turn as the shell asks for the next, as bash 3.2 does with its PS2; only a
        // tab, which would complete, needs the paste.
        features::history::HistoryText::validate(text.view(), bracketed || !text.view().contains('\t'));
        // What the history does not keep, the suggestions do not offer.
        const bool kept = session.configuration.history_filters.allowsPane(text.view(), std::string_view{pane->cwd});

        const auto request_id = session.runCommand(pane_id, text.view());
        // Sending reaches the session, so the line is found again.
        auto* sent = features::prompt::find(session.prompt_lines, pane_id);
        if (!request_id || sent == nullptr) {
          break;
        }

        if (*request_id != 0 && features::prompt::sent(session.prompt, *sent, *request_id, text.view(), kept)) {
          break;
        }

        features::prompt::committed(*sent, kept ? text.view() : std::string_view{});
        if (kept) {
          features::prompt::remember(session.prompt, text.view(), place(session, pane_id));
        }

        break;
      }
      case Outcome::answer: {
        const auto answer = features::prompt::oneLine(text.view());
        if (!answer) {
          throw EncodingError{"An answer is one line: the program would read the next as another answer, or the shell as a command"};
        }

        // A tab is the program's to read; controls are refused as in a command.
        features::history::HistoryText::validate(answer->empty() ? std::string_view{" "} : *answer, true);
        ds::String<Memory> sent{session.memory, *answer};

        sent.push('\r');
        session.input(pane_id, sent.view());
        if (auto* line_sent = features::prompt::find(session.prompt_lines, pane_id)) {
          features::prompt::committed(*line_sent, {});
        }

        break;
      }
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

    // The command pane `pane_id`'s line ran ended with `status`: one the shell did not find has the
    // empty line suggest the closest command known, and the runtime asked for the commands that
    // start as it does, for one closer still. A remote shell's commands are on its host.
    void mistyped(Session& session, const PaneShell& ended) {
      const auto pane_id = ended.pane_id;
      const auto status = ended.status;
      const auto* pane = findPane(session.panes, pane_id);
      auto* line = features::prompt::find(session.prompt_lines, pane_id);
      if (pane == nullptr || line == nullptr) {
        return;
      }

      const auto request_id = session.link.nextRequest();
      const bool asks = session.ready() && !pane->shell.remote;
      const auto question = features::prompt::mistyped(session.prompt, *line, status, dialect(*pane), asks ? ds::Option{request_id} : ds::none);

      if (question) {
        features::prompt::askedCorrection(session.prompt, request_id, session.link.offer(*question));
      }
    }

    // Asks the runtime's index for the command it ranks first for what pane `pane_id`'s line
    // holds, weighed for the pane and its directory; once the question in flight is answered when
    // one is. Only a runtime that ranks (cqp00015) and while suggestions show.
    void askSuggestion(Session& session, std::uint64_t pane_id) {
      const auto* pane = findPane(session.panes, pane_id);
      auto* line = features::prompt::find(session.prompt_lines, pane_id);
      if (pane == nullptr || line == nullptr || !session.ready() || !session.configuration.prompt.ghost || !session.speaks(ClientTag::watch_history)) {
        return;
      }

      if (line->suggesting != 0) {
        line->suggest_again = true;
        return;
      }

      const auto request_id = session.link.nextRequest();
      // The pane and its directory weigh the ranking; the workspace is the runtime's to know.
      const auto query = features::prompt::suggestionQuery(*line, {.pane_id = pane_id, .directory = std::string_view{pane->cwd}}, request_id);

      if (!query) {
        return;
      }

      const bool sent = session.link.offer(*query);

      if (auto* asked = features::prompt::find(session.prompt_lines, pane_id)) {
        features::prompt::askedSuggestion(session.prompt, *asked, request_id, sent);
      }
    }

    // The last key took the runtime's suggestion whole: the runtime learns which entry was chosen.
    void tellChosen(Session& session, std::uint64_t pane_id) {
      auto* line = features::prompt::find(session.prompt_lines, pane_id);
      const auto chosen = line == nullptr ? ds::none : features::prompt::takeChosen(*line);
      if (chosen && session.speaks(ClientTag::choose_history_entry)) {
        static_cast<void>(session.link.ask(ChooseHistoryEntry{.id = *chosen, .pane_id = pane_id}));
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

    return where == Surface::editor || where == Surface::running || (where == Surface::none && betweenCommands(session, pane_id));
  }

  bool toProgram(Session& session, std::uint64_t pane_id, std::string_view text) {
    if (surface(session, pane_id) != Surface::running) {
      return false;
    }

    static_cast<void>(open(session, pane_id));

    const auto question = asked(*findPane(session.panes, pane_id));
    auto& line = *features::prompt::find(session.prompt_lines, pane_id);
    const auto clock = Access::clock(session);
    const auto now = [clock] {
      return clock();
    };

    return features::prompt::toProgram(line, text, question.view(), now);
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
      return afterCommand(session, *pane);
    case Surface::editor:
    case Surface::secret:
      break;
    }

    return false;
  }

  ds::Option<LineView> line(const Session& session, std::uint64_t pane_id) noexcept {
    return features::prompt::line(session.prompt, session.prompt_lines, pane_id, place(session, pane_id));
  }

  std::string_view suggestion(const Session& session, std::uint64_t pane_id) noexcept {
    const auto typed = line(session, pane_id);

    return typed ? typed->suggestion() : std::string_view{};
  }

  features::prompt::Recalled history(const Session& session) noexcept {
    return features::prompt::history(session.prompt);
  }

  Outcome key(Session& session, std::uint64_t pane_id, const KeyPress& key) {
    const auto shown = surface(session, pane_id);
    // Between a command's end and the prompt no program reads the keys: they queue.
    const auto where = shown == Surface::none && betweenCommands(session, pane_id) ? Surface::running : shown;
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

    // What the program asked is read only while one runs, the one time a key may answer it.
    if (shown == Surface::running) {
      const auto question = asked(*pane);
      if (features::prompt::toProgram(line, key, pane->shell, question.view(), now)) {
        return Outcome::terminal;
      }
    }

    const auto shell = dialect(*pane);
    const auto outcome = features::prompt::press(session.prompt, line, where, key, {.configuration = session.configuration.prompt, .dialect = shell, .place = place(session, *pane)});
    if (outcome == Outcome::complete) {
      complete(session, pane_id, shell);
      return Outcome::edited;
    }

    deliver(session, pane_id, outcome);
    if (outcome == Outcome::edited && where == Surface::editor) {
      tellChosen(session, pane_id);
      askSuggestion(session, pane_id);
    }

    return outcome;
  }

  void text(Session& session, std::uint64_t pane_id, std::string_view text) {
    static_cast<void>(open(session, pane_id));
    auto* line = features::prompt::find(session.prompt_lines, pane_id);
    if (line != nullptr && features::prompt::insert(session.prompt, *line, text)) {
      askSuggestion(session, pane_id);
      return;
    }

    if (line == nullptr) {
      return;
    }

    // A paste the line cannot hold is refused whole: the person learns why nothing came.
    notifications::reportLimit(session, {.name = "prompt.command_bytes", .noun = "bytes", .value = features::prompt::line_capacity, .requested = line->line.editor().text().size() + text.size(), .route = {}});
  }

  void textCommand(Session& session, std::uint64_t pane_id, TextCommand command) {
    auto* line = features::prompt::find(session.prompt_lines, pane_id);
    if (line == nullptr) {
      return;
    }

    auto& text = line->line.editorMut().textMut();

    switch (command) {
    case TextCommand::select_all:
      text.select(0, text.size());
      break;
    case TextCommand::redo:
      static_cast<void>(text.redo());
      break;
    case TextCommand::erase_selection:
      if (text.selecting()) {
        static_cast<void>(text.insert({}));
      }

      break;
    }

    Access::changedPane(session) = pane_id;
  }

  void placeCursor(Session& session, std::uint64_t pane_id, std::size_t offset) { // NOLINT(bugprone-easily-swappable-parameters): the pane, then where in its line, as every use case of the prompt takes them
    if (auto* line = features::prompt::find(session.prompt_lines, pane_id)) {
      line->line.editorMut().textMut().moveTo(offset);
      Access::changedPane(session) = pane_id;
    }
  }

  void reconvert(Session& session, std::uint64_t pane_id, Surrounding replaced, std::string_view text) {
    if (auto* line = features::prompt::find(session.prompt_lines, pane_id)) {
      line->line.editorMut().textMut().select(replaced.begin, replaced.end);
    }

    prompt::text(session, pane_id, text);
  }

  std::string_view selectedText(const Session& session, std::uint64_t pane_id) noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    const auto typed = line(session, pane_id);
    if (!typed) {
      return {};
    }

    const auto start = std::min(typed->cursor(), typed->anchor());
    const auto end = std::max(typed->cursor(), typed->anchor());

    return typed->text().substr(start, end - start);
  }

  CommandPresence commandPresence(Session& session, std::uint64_t pane_id, std::string_view word) {
    const auto* pane = findPane(session.panes, pane_id);
    if (pane == nullptr || pane->shell.remote || !session.ready()) {
      return CommandPresence::unknown;
    }

    const bool reads_directories = session.speaks(handshake::directory_words);
    auto& state = session.prompt;
    const auto asked = commands(*pane);
    if (const auto known = features::prompt::presence(state, asked, word)) {
      return *known;
    }

    const auto request_id = session.link.nextRequest();

    try {
      const auto query = features::prompt::ask(state.command_root, asked, word, request_id, reads_directories);
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

  ds::Option<std::pair<std::size_t, std::size_t>> rejectedOption(Session& session, std::uint64_t pane_id) {
    const auto* pane = findPane(session.panes, pane_id);
    auto* line = features::prompt::find(session.prompt_lines, pane_id);

    return pane == nullptr || line == nullptr ? ds::none : features::prompt::rejectedOption(session.prompt, *line, dialect(*pane));
  }

  ds::Option<std::uint64_t> takeWrite(Session& session) noexcept {
    return features::prompt::takeWrite(session.prompt);
  }

  features::prompt::PaneLine& open(Session& session, std::uint64_t pane_id) {
    const auto keymap = session.configuration.prompt.keymap == PromptKeymap::vim ? Keymap::vim : Keymap::emacs;
    if (features::prompt::open(session.prompt, session.prompt_lines, pane_id, keymap).wants_history) {
      requestHistory(session);
    }

    auto* line = features::prompt::find(session.prompt_lines, pane_id);
    if (line == nullptr) {
      throw std::logic_error{"Opened prompt line missing"};
    }

    return *line;
  }

  void write(Session& session, std::uint64_t pane_id, std::string_view command) {
    static_cast<void>(open(session, pane_id));
    if (auto* line = features::prompt::find(session.prompt_lines, pane_id)) {
      features::prompt::write(session.prompt, *line, command);
    }
  }

  void typeSecret(Session& session, std::uint64_t pane_id, char byte) {
    features::prompt::typeSecret(open(session, pane_id), byte);
  }

  void follow(Session& session, std::uint64_t pane_id, const PaneShell& previous, const PaneShell& current) {
    if (features::prompt::find(session.prompt_lines, pane_id) == nullptr) {
      return;
    }

    // A command quicker than the runtime's delivery is never seen running: the shell is back at a
    // prompt of its own once a command ended there too.
    const bool back_at_prompt = current.phase == ShellPhase::prompt && (previous.phase != ShellPhase::prompt || current.commands != previous.commands);

    // A command ended: one the shell did not find is corrected, before the line forgets it ran.
    if (current.commands != previous.commands) {
      mistyped(session, current);
      if (auto* ran = features::prompt::find(session.prompt_lines, pane_id)) {
        features::prompt::ended(session.prompt, *ran, current.status);
      }
    }

    auto* line = features::prompt::find(session.prompt_lines, pane_id);
    if (line == nullptr) {
      return;
    }

    if (const auto outcome = features::prompt::follow(*line, previous, current, static_cast<std::int64_t>(Access::clock(session)()))) {
      deliver(session, pane_id, *outcome);
    }

    // What the shell's own line held when the last command cleared it comes back into the line.
    if (back_at_prompt) {
      if (auto* back = features::prompt::find(session.prompt_lines, pane_id); back != nullptr && features::prompt::takeTypeahead(session.prompt, *back)) {
        Access::changedPane(session) = pane_id;
      }
    }

    // A history that never arrived is asked for again each time a shell is back at its prompt.
    if (back_at_prompt && features::prompt::historyWanted(session.prompt)) {
      requestHistory(session);
    }
  }

  void connected(Session& session) {
    // The history's changes reach the suggestions and Up as they happen.
    if (session.speaks(ClientTag::watch_history)) {
      static_cast<void>(session.link.ask(WatchHistory{.watch = true}));
    }

    if (!session.prompt_lines.empty() && features::prompt::historyWanted(session.prompt)) {
      requestHistory(session);
    }
  }

  Change receive(Session& session, const PaneTypeahead& message) {
    if (findPane(session.panes, message.pane_id) != nullptr) {
      features::prompt::typeahead(open(session, message.pane_id), message.text);
    }

    return Change::none;
  }

  Change receive(Session& session, const HistoryChanged& /*message*/) {
    features::prompt::historyStale(session.prompt);
    if (session.prompt_lines.empty()) {
      return Change::none;
    }

    requestHistory(session);
    // The panes first: asking reaches the lines.
    ds::Vec<std::uint64_t, Memory> panes{session.memory};

    for (const auto& entry : session.prompt_lines) {
      panes.push(entry.key);
    }

    for (const auto pane_id : panes) {
      askSuggestion(session, pane_id);
    }

    return Change::none;
  }

  ds::Option<Change> receive(Session& session, const HistoryResults& message) {
    if (const auto pane_id = features::prompt::ranked(session.prompt, session.prompt_lines, message)) {
      // Typed on while it was asked: the line asks for what it holds now.
      if (const auto* line = features::prompt::find(session.prompt_lines, *pane_id); line != nullptr && line->suggest_again) {
        askSuggestion(session, *pane_id);
      }

      return changed(session, *pane_id);
    }

    if (features::prompt::receive(session.prompt, message)) {
      // Changes that came while it was on its way are read now, once for them all.
      if (features::prompt::historyWanted(session.prompt)) {
        requestHistory(session);
      }

      return Change::none;
    }

    return ds::none;
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
    if (const auto corrected = features::prompt::correct(session.prompt, session.prompt_lines, message)) {
      return changed(session, *corrected);
    }

    if (const auto settled = features::prompt::settles(session.prompt, message)) {
      return settle(session, *settled);
    }

    const auto pane_id = features::prompt::receive(session.prompt, session.prompt_lines, message).valueOr(0);

    askAgain(session, pane_id);
    return changed(session, pane_id);
  }

  ds::Option<Change> receive(Session& session, const PathResults& message) {
    if (const auto settled = features::prompt::settles(session.prompt, message)) {
      return settle(session, *settled);
    }

    const auto pane_id = features::prompt::receive(session.prompt, session.prompt_lines, message);
    if (!pane_id) {
      return ds::none;
    }

    askAgain(session, *pane_id);
    return changed(session, *pane_id);
  }

  bool completed(Session& session, std::uint64_t request_id) {
    const auto pane_id = features::prompt::sentFrom(session.prompt, request_id);

    return pane_id && features::prompt::accepted(session.prompt, session.prompt_lines, request_id, place(session, *pane_id));
  }

  ds::Option<Change> fail(Session& session, const RequestFailed& message) {
    const auto request_id = message.request_id;

    // A command the pane refused is back in its line; the person learns why it did not run.
    if (const auto refused = features::prompt::refused(session.prompt, session.prompt_lines, request_id)) {
      const auto pane_id = refused->pane_id;

      notifications::publish(session, {.level = NotificationLevel::warning, .target = {.kind = NotificationTarget::Kind::pane, .id = pane_id}, .title = "The command did not run", .message = message.message, .link = {}});
      return changed(session, pane_id);
    }

    const auto pane_id = features::prompt::fail(session.prompt, session.prompt_lines, request_id);
    if (!pane_id) {
      return ds::none;
    }

    return changed(session, *pane_id);
  }

}
