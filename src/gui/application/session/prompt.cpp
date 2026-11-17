module telar.gui.application.session;

import std;
import telar.base.text.utf8;
import telar.ebnf.matcher;
import telar.gui.input.configuration;
import telar.gui.foundation.core;

namespace telar::gui {

  prompt::Surface Session::promptSurface(std::uint64_t pane_id) const noexcept {
    const auto* pane = findPane(pane_id);
    // telar's editor stays while copy mode, which owns the keys, reads the scrollback.
    if (pane == nullptr || !pane->attached || pane->exited || (copy_mode_.active() && configuration_.prompt.mode != PromptMode::telar)) {
      return prompt::Surface::none;
    }

    return prompt::surface(pane->shell, pane->screen.modes().alternate_screen, configuration_.prompt.mode == PromptMode::telar);
  }

  std::optional<std::uint64_t> Session::takePromptWrite() noexcept {
    const auto written = std::exchange(prompt_written_, 0);

    return written == 0 ? std::nullopt : std::optional{written};
  }

  bool Session::takeBlockChange() noexcept {
    return std::exchange(block_changed_, false);
  }

  bool Session::takeClipboardWrite() noexcept {
    return std::exchange(clipboard_written_, false);
  }

  bool Session::editsPrompt(std::uint64_t pane_id) const noexcept {
    const auto surface = promptSurface(pane_id);

    return surface == prompt::Surface::editor || surface == prompt::Surface::running;
  }

  bool Session::hidesTerminalCursor(std::uint64_t pane_id) const noexcept {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return false;
    }

    const auto surface = promptSurface(pane_id);
    // At the prompt every key goes to telar's editor, whatever frame the terminal still shows.
    if (surface == prompt::Surface::editor) {
      return true;
    }

    if (pane->screen.cursor().x != 0) {
      return false;
    }

    switch (surface) {
    case prompt::Surface::running: {
      const auto found = lines_.find(pane_id);

      return found == lines_.end() || !found->second.line.answering();
    }
    case prompt::Surface::none:
      return configuration_.prompt.mode == PromptMode::telar && pane->attached && !pane->exited && pane->shell.shell != IntegratedShell::none && pane->shell.phase == ShellPhase::unknown && pane->shell.commands != 0 && !pane->screen.modes().alternate_screen;
    case prompt::Surface::editor:
    case prompt::Surface::secret:
      break;
    }

    return false;
  }

  std::span<const std::string> Session::promptHistory() const noexcept {
    return prompt_history_;
  }

  const prompt::Line* Session::promptLine(std::uint64_t pane_id) const noexcept {
    const auto found = lines_.find(pane_id);

    return found == lines_.end() ? nullptr : &found->second.line;
  }

  prompt::Outcome Session::promptKey(std::uint64_t pane_id, const prompt::KeyPress& key) {
    const auto surface = promptSurface(pane_id);
    if (surface != prompt::Surface::editor && surface != prompt::Surface::running) {
      return prompt::Outcome::terminal;
    }

    auto& entry = lineEntry(pane_id);

    if (surface == prompt::Surface::editor) {
      if (const auto outcome = blockKey(pane_id, entry, key)) {
        return *outcome;
      }
    }

    if (surface == prompt::Surface::running && !entry.line.answering()) {
      const auto* pane = findPane(pane_id);

      // Signal and end-of-file keys always reach the program, as does typing while it seems
      // to ask a question.
      if (key.key == prompt::Key::character && key.modifiers.control && !key.modifiers.alt && key.character < 0x80) {
        const char control = static_cast<char>(key.character & 0x1f);
        if (prompt::controlKey(pane->shell, {&control, 1})) {
          return prompt::Outcome::terminal;
        }
      }

      if (entry.line.editor().text().empty() && prompt::PendingPrompt::likely(pane->screen.cursor().x, std::chrono::nanoseconds{now_() - entry.output})) {
        return prompt::Outcome::terminal;
      }
    }

    const auto syntax = shell::Syntax{.dialect = findPane(pane_id)->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix};
    const auto incomplete = [syntax](std::string_view text) {
      return prompt::incomplete(text, syntax);
    };

    const auto bound = boundAction(key, entry.line.editor());
    const auto outcome = bound ? entry.line.perform(surface, *bound, incomplete, prompt_history_) : entry.line.press(surface, key, incomplete, prompt_history_);
    if (outcome == prompt::Outcome::complete) {
      beginCompletion(pane_id, entry.line, syntax);
      return prompt::Outcome::edited;
    }

    deliverPrompt(pane_id, outcome, entry.line);
    return outcome;
  }

  CommandPresence Session::commandPresence(std::uint64_t pane_id, std::string_view word) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || pane->shell.remote || !ready_ || word.empty() || word.size() > 256) {
      return CommandPresence::unknown;
    }

    auto& checks = commandChecks(*pane);
    if (checks.learned.contains(word)) {
      return CommandPresence::found;
    }

    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      return known->second;
    }

    if (word.find('/') == std::string_view::npos) {
      for (const auto& [prefix, commands] : checks.listed) {
        if (word.starts_with(prefix)) {
          const auto presence = std::ranges::find(commands, word) != commands.end() ? CommandPresence::found : CommandPresence::missing;

          checks.words.emplace(std::string{word}, presence);
          return presence;
        }
      }
    }

    const auto request_id = nextRequest();

    try {
      const auto slash = word.rfind('/');
      if (slash == std::string_view::npos) {
        send(CompleteWords{.request_id = request_id, .pane_id = pane_id, .provider = CompletionProvider::command, .prefix = word});
      } else {
        // A command named by its path: a file there, from the directory the shell is in.
        std::string root{word.starts_with('/') ? std::string_view{} : std::string_view{pane->cwd}};

        if (!word.starts_with('/')) {
          root.push_back('/');
        }

        root.append(word.substr(0, slash));
        while (root.size() > 1 && root.ends_with('/')) {
          root.pop_back();
        }

        const auto name = word.substr(slash + 1);
        if (name.empty() || name.size() > 64 || !root.starts_with('/')) {
          return CommandPresence::unknown;
        }

        send(FindPaths{.request_id = request_id, .root = root, .query = name, .kind = PathKindFilter::any, .limit = 50});
      }
    } catch (const std::exception&) {
      checks.words.emplace(std::string{word}, CommandPresence::unknown);
      return CommandPresence::unknown;
    }

    checks.words.emplace(std::string{word}, CommandPresence::pending);
    command_requests_.emplace(request_id, CommandRequest{pane_id, std::string{word}});
    return CommandPresence::pending;
  }

  bool Session::takeChromeChange() noexcept {
    return std::exchange(chrome_changed_, false);
  }

  void Session::scrollToRow(std::uint64_t pane_id, std::uint32_t row) {
    const auto* pane = findPane(pane_id);
    if (pane != nullptr) {
      scroll(PaneScrollDelta{.pane_id = pane_id, .rows = static_cast<std::int64_t>(pane->screen.scroll().offset) - static_cast<std::int64_t>(row)});
    }
  }

  void Session::promptText(std::uint64_t pane_id, std::string_view text) {
    std::string clean;

    clean.reserve(text.size());
    for (const auto byte : text) {
      const auto value = static_cast<unsigned char>(byte);
      if (value >= 0x20 || byte == '\n' || byte == '\t') {
        clean.push_back(value == 0x7f ? ' ' : byte);
      }
    }

    lineEntry(pane_id).line.insertText(clean);
    prompt_written_ = pane_id;
  }

  void Session::paste(std::uint64_t pane_id, std::string_view bytes) {
    if (copy_mode_.active()) {
      return;
    }

    if (editsPrompt(pane_id)) {
      promptText(pane_id, bytes);
      return;
    }

    pasteBytes(pane_id, bytes);
  }

  void Session::pasteBytes(std::uint64_t pane_id, std::string_view bytes) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return;
    }

    BracketedPaste::encode(bytes, pane->screen.modes().bracketed_paste, [&](std::string_view piece) {
      input(pane_id, piece);
    });
  }

  void Session::pasteHistory(std::uint64_t entry_id, bool alternate) {
    // The entry is copied out of the history, which pasting must not be able to reach.
    const String<Memory> entry{history_.command(entry_id), AllocatorRef<char, Memory>{memory_}};
    const std::string_view command = entry;
    const auto* pane = focusedPane();
    if (pane == nullptr || !pane->attached || pane->exited) {
      throw EncodingError{"No terminal is ready for input"};
    }

    if (editsPrompt(pane->id)) {
      auto& text = lineEntry(pane->id).line.editor().text();

      text.assign(command);
      text.moveTo(text.size());
      prompt_written_ = pane->id;
      if (configuration_.history.enter_runs != alternate) {
        promptKey(pane->id, prompt::KeyPress{prompt::Key::enter});
      }

      return;
    }

    HistoryText::validate(command, pane->screen.modes().bracketed_paste);
    paste(pane->id, command);
    if (configuration_.history.enter_runs != alternate) {
      input(pane->id, "\r");
    }
  }

  void Session::copyHistory(std::uint64_t entry_id) {
    clipboard_ = history_.command(entry_id);
  }

  void Session::beginSuggestion() noexcept {
    suggestion_.begin();
  }

  void Session::invalidateSuggestion() noexcept {
    suggestion_.invalidate();
  }

  const SuggestionState& Session::suggestion() const noexcept {
    return suggestion_;
  }

  bool Session::submitSuggestion(std::string_view text) {
    const auto* pane = focusedPane();

    if (suggestion_.phase() == SuggestionPhase::ready) {
      if (!ready_ || pane == nullptr || !pane->attached || pane->exited || copy_mode_.active()) {
        return false;
      }

      if (editsPrompt(pane->id)) {
        promptText(pane->id, suggestion_.text());
        return true;
      }

      const auto bracketed = pane->screen.modes().bracketed_paste;

      HistoryText::validate(suggestion_.text(), bracketed);
      const auto encoded = PasteEncoding::encode<SuggestionLimits::text_bytes>(suggestion_.text(), bracketed);

      input(pane->id, encoded.view());

      return true;
    }

    if (text.empty() || suggestion_.phase() == SuggestionPhase::waiting) {
      return false;
    }

    if (!ready_ || pane == nullptr || !pane->attached || pane->exited) {
      constexpr std::uint64_t failed_request = 1;

      suggestion_.expect(failed_request);
      static_cast<void>(suggestion_.receive({.request_id = failed_request, .status = SuggestionStatus::failed}));

      return false;
    }

    const SuggestCommand request{.request_id = nextRequest(), .pane_id = pane->id, .text = text};

    send(request);
    suggestion_.expect(request.request_id);

    return false;
  }

  bool Session::beginPathPicker() {
    const auto* pane = focusedPane();
    if (!ready_ || copy_mode_.active() || pane == nullptr || !pane->attached || pane->exited || !std::string_view{pane->cwd}.starts_with('/')) {
      return false;
    }

    path_picker_.begin(pane->id, pane->cwd);
    seedPathPicker(pane->id);
    requestPaths(path_seed_.text.view());

    return true;
  }

  std::string_view Session::pathSeed() const noexcept {
    return path_seed_.text.view();
  }

  bool Session::requestPaths(std::string_view query) {
    if (!ready_ || path_picker_.paneId() == 0) {
      return false;
    }

    const FindPaths request{
        .request_id = nextRequest(),
        .root = path_picker_.root(),
        .query = runtime::utf8Prefix(query, PathPickerLimits::query_bytes),
        .kind = PathKindFilter::any,
        .limit = static_cast<std::uint16_t>(PathPickerLimits::results),
        .refresh = path_picker_.refreshRequested(),
    };

    try {
      send(request);
    } catch (const std::length_error&) {
      path_picker_.setError("Path request queue is full; retry");

      return false;
    }

    path_picker_.expect(request.request_id);

    return true;
  }

  bool Session::descendPath(std::size_t selection) {
    const auto matches = path_picker_.matches();
    if (matches.empty()) {
      return false;
    }

    const auto& match = matches[std::min(selection, matches.size() - 1)];
    if (match.kind != PathKind::directory) {
      return false;
    }

    auto relative = path_picker_.path(match);
    const auto last = relative.find_last_not_of('/');

    relative.remove_suffix(last == std::string_view::npos ? relative.size() : relative.size() - last - 1);
    const auto directory = PathInsertion::join({.root = path_picker_.root(), .relative = relative});
    if (directory.view().size() > PathPickerLimits::root_bytes) {
      return false;
    }

    path_picker_.setRoot(directory.view());
    requestPaths({});

    return true;
  }

  bool Session::ascendPath() {
    const auto root = path_picker_.root();
    if (root.size() <= 1) {
      return false;
    }

    const auto separator = root.rfind('/');
    if (separator == std::string_view::npos) {
      return false;
    }

    path_picker_.setRoot(separator == 0 ? root.substr(0, 1) : root.substr(0, separator));
    requestPaths({});

    return true;
  }

  void Session::closePathPicker() noexcept {
    path_picker_.close();
    path_seed_ = {};
  }

  bool Session::insertPath(std::size_t selection, bool absolute) {
    if (path_picker_.matches().empty()) {
      path_picker_.setError(path_picker_.phase() == PathPickerPhase::loading ? "Searching..." : "No path to insert");

      return false;
    }

    const auto* pane = focusedPane();
    if (!ready_ || pane == nullptr || !pane->attached || pane->exited || copy_mode_.active()) {
      path_picker_.setError("Input is busy; retry");

      return false;
    }

    const bool editor = editsPrompt(pane->id);
    const auto paste = PathInsertion::prepare(path_picker_, {.selection = selection, .absolute = absolute, .bracketed = !editor && pane->screen.modes().bracketed_paste});
    if (!paste) {
      return false;
    }

    try {
      if (editor && replacePathSeed(pane->id, paste->view())) {
        prompt_written_ = pane->id;
      } else if (editor) {
        promptText(pane->id, paste->view());
      } else {
        input(pane->id, paste->view());
      }
    } catch (const std::length_error&) {
      path_picker_.setError("Input is busy; retry");

      return false;
    }

    closePathPicker();

    return true;
  }

  const PathPickerPage& Session::pathPicker() const noexcept {
    return path_picker_;
  }

  void Session::seedPathPicker(std::uint64_t pane_id) {
    path_seed_ = {};
    const auto found = lines_.find(pane_id);
    if (promptSurface(pane_id) != prompt::Surface::editor || found == lines_.end()) {
      return;
    }

    const auto& text = found->second.line.editor().text();
    const auto before = text.view().substr(0, text.cursor());
    const auto space = before.find_last_of(" \t\n");
    const auto begin = space == std::string_view::npos ? 0 : space + 1;
    const auto word = before.substr(begin);
    if (word.empty() || word.size() > PathPickerLimits::query_bytes || word.front() == '/' || word.front() == '~' || !PathInsertion::plain(word)) {
      return;
    }

    path_seed_.pane_id = pane_id;
    path_seed_.begin = begin;
    path_seed_.text.assign(word);
  }

  bool Session::replacePathSeed(std::uint64_t pane_id, std::string_view path) {
    const auto word = path_seed_.text.view();
    const auto found = lines_.find(pane_id);
    if (path_seed_.pane_id != pane_id || word.empty() || found == lines_.end()) {
      return false;
    }

    auto& line = found->second.line;
    const auto& text = line.editor().text();
    const auto end = path_seed_.begin + word.size();
    if (text.cursor() != end || text.view().substr(path_seed_.begin, word.size()) != word) {
      return false;
    }

    line.replaceText(path_seed_.begin, end, path);
    return true;
  }

  Change Session::apply(const CommandSpec& message) {
    const auto request = spec_requests_.find(message.request_id);
    if (request == spec_requests_.end()) {
      return Change::none;
    }

    const auto [pane_id, command] = std::move(request->second);

    spec_requests_.erase(request);
    // An alias's spec is the one of the command it stands for, kept under that command's name.
    const auto expansion = message.command == command ? message.expansion : std::string_view{};
    const auto target = expansion.empty() ? std::string_view{command} : expansion.substr(0, expansion.find(' '));
    auto state = SpecState::unavailable;

    if (message.state == CommandSpecState::available && message.command == command) {
      state = prompt_specs_.install(target, message.digest, message.source) ? SpecState::available : SpecState::unavailable;
    } else if (message.state == CommandSpecState::unchanged && prompt_specs_.find(target) != nullptr && prompt_specs_.digest(target) == message.digest) {
      state = SpecState::available;
    }

    auto& checks = command_checks_[pane_id];
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      known->second = state;
    }

    if (state == SpecState::available && !expansion.empty()) {
      checks.aliases.insert_or_assign(command, std::string{expansion});
      if (checks.alias_targets.size() >= 256) {
        checks.alias_targets.clear();
      }

      checks.alias_targets.insert_or_assign(command, std::string{target});
    }

    // A Tab that waited for it completes now, if the line is still the one it was for.
    const auto waiting = spec_completions_.find(pane_id);
    const auto line = lines_.find(pane_id);
    const auto* pane = findPane(pane_id);
    if (waiting == spec_completions_.end() || line == lines_.end() || pane == nullptr) {
      return Change::none;
    }

    const bool same = waiting->second == line->second.line.editor().text().view();

    spec_completions_.erase(waiting);
    if (!same) {
      return Change::none;
    }

    beginCompletion(pane_id, line->second.line, shell::Syntax{.dialect = pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix});
    changed_pane_ = pane_id;
    return Change::terminal;
  }

  Change Session::apply(const CompletionWords& message) {
    if (const auto checked = command_requests_.find(message.request_id); checked != command_requests_.end()) {
      const auto found = std::ranges::any_of(message.words, [&](const CompletionWord& word) {
        return word.text == checked->second.word;
      });

      if (!message.truncated) {
        listCommands(checked->second.pane_id, checked->second.word, message.words);
      }

      return settleCommand(checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown
                                                                                       : CommandPresence::missing);
    }

    const auto pending = path_completions_.find(message.request_id);
    if (pending == path_completions_.end()) {
      return Change::none;
    }

    const auto [pane_id, base, query] = std::move(pending->second);

    path_completions_.erase(pending);
    const auto line = lines_.find(pane_id);
    if (line == lines_.end()) {
      return Change::none;
    }

    std::vector<prompt::Choice> words;

    for (const auto& word : message.words) {
      words.push_back({.text = base + std::string{word.text}, .description = std::string{word.description}});
    }

    line->second.line.receive(message.request_id, words, message.truncated);
    changed_pane_ = pane_id;
    return Change::terminal;
  }

  Change Session::apply(const PathResults& message) {
    if (const auto checked = command_requests_.find(message.request_id); checked != command_requests_.end()) {
      const auto name = std::string_view{checked->second.word}.substr(checked->second.word.rfind('/') + 1);
      const auto found = std::ranges::any_of(message.matches, [&](const PathMatch& match) {
        return match.kind != PathKind::directory && match.path == name;
      });

      return settleCommand(checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown
                                                                                       : CommandPresence::missing);
    }

    if (const auto pending = path_completions_.find(message.request_id); pending != path_completions_.end()) {
      const auto [pane_id, base, query] = std::move(pending->second);

      path_completions_.erase(pending);
      if (const auto line = lines_.find(pane_id); line != lines_.end()) {
        // The shell completes one directory at a time: children of the root that start with
        // what was typed, not the deeper matches the search also finds.
        std::vector<prompt::Choice> paths;

        for (const auto& match : message.matches) {
          // Directories arrive with their trailing slash.
          const bool directory = match.kind == PathKind::directory;
          const auto name = directory ? match.path.substr(0, match.path.size() - 1) : match.path;
          if (name.find('/') == std::string_view::npos && name.starts_with(query)) {
            paths.push_back({.text = base + std::string{match.path}, .directory = directory});
          }
        }

        line->second.line.receive(message.request_id, paths, message.truncated);
        changed_pane_ = pane_id;
        return Change::terminal;
      }

      return Change::none;
    }

    return path_picker_.receive(message) ? Change::paths : Change::none;
  }

  Change Session::apply(const CommandSuggestion& message) {
    return suggestion_.receive(message) ? Change::suggestion : Change::none;
  }

  std::optional<std::uint32_t> Session::livePromptRow(const Pane<Memory>& pane) {
    const auto& screen = pane.screen;
    const auto& scroll = screen.scroll();
    if (static_cast<std::uint64_t>(scroll.offset) + screen.rows() < scroll.total_rows) {
      return std::nullopt;
    }

    const auto cursor = static_cast<std::size_t>(screen.cursor().y);

    for (auto row = cursor + 1; row-- > 0 && cursor - row < 8;) {
      if ((screen.rowFlags(row) & static_cast<Byte>(RowFlag::prompt)) != 0) {
        return scroll.offset + static_cast<std::uint32_t>(row);
      }
    }

    return std::nullopt;
  }

  auto Session::lineEntry(std::uint64_t pane_id) -> LineEntry& {
    const auto keymap = configuration_.prompt.keymap == PromptKeymap::vim ? prompt::Keymap::vim : prompt::Keymap::emacs;
    auto [found, inserted] = lines_.try_emplace(pane_id, LineEntry{.line = prompt::Line{keymap}});

    found->second.line.setKeymap(keymap);
    if (inserted && prompt_history_.empty()) {
      requestPromptHistory();
    }

    return found->second;
  }

  void Session::requestPromptHistory() {
    if (!ready_ || !configuration_.prompt.ghost || prompt_history_request_ != 0) {
      return;
    }

    const QueryHistory query{.request_id = nextRequest(), .author = HistoryAuthorFilter::human, .distinct = true, .limit = prompt_history_limit};

    try {
      send(query);
      prompt_history_request_ = query.request_id;
    } catch (const std::length_error&) {
    }
  }

  std::optional<prompt::Action> Session::boundAction(const prompt::KeyPress& key, const prompt::Editor& editor) const {
    using Chord = runtime::config::KeyChord;
    const bool normal = editor.keymap() == prompt::Keymap::vim && editor.mode() != prompt::Mode::insert;
    const auto named = [&]() -> std::optional<Chord::Key> {
      switch (key.key) {
      case prompt::Key::character:
        return Chord::Key::character;
      case prompt::Key::enter:
        return Chord::Key::enter;
      case prompt::Key::backspace:
        return Chord::Key::backspace;
      case prompt::Key::delete_forward:
        return Chord::Key::erase;
      case prompt::Key::left:
        return Chord::Key::left;
      case prompt::Key::right:
        return Chord::Key::right;
      case prompt::Key::up:
        return Chord::Key::up;
      case prompt::Key::down:
        return Chord::Key::down;
      case prompt::Key::home:
        return Chord::Key::home;
      case prompt::Key::end:
        return Chord::Key::end;
      case prompt::Key::tab:
        return Chord::Key::tab;
      case prompt::Key::backtab:
        return Chord::Key::back_tab;
      case prompt::Key::escape:
        return Chord::Key::escape;
      }

      return std::nullopt;
    }();
    if (!named) {
      return std::nullopt;
    }

    unsigned modifiers = (key.modifiers.control ? static_cast<unsigned>(Chord::Modifier::control) : 0U) | (key.modifiers.alt ? static_cast<unsigned>(Chord::Modifier::alt) : 0U);

    // A shifted character is its own character; Shift counts only with named keys.
    if (*named != Chord::Key::character && key.modifiers.shift) {
      modifiers |= static_cast<unsigned>(Chord::Modifier::shift);
    }

    const auto character = *named == Chord::Key::character ? KeyCharacter::pack(key.character) : 0U;

    for (const auto& binding : configuration_.prompt.bindings) {
      if (binding.normal == normal && binding.key == static_cast<std::uint8_t>(*named) && binding.modifiers == modifiers && binding.character == character) {
        return static_cast<prompt::Action>(binding.action);
      }
    }

    return std::nullopt;
  }

  void Session::deliverPrompt(std::uint64_t pane_id, prompt::Outcome outcome, const prompt::Line& line) {
    const auto* pane = findPane(pane_id);
    if (pane == nullptr || !pane->attached || pane->exited) {
      return;
    }

    const auto text = line.delivery();

    switch (outcome) {
    case prompt::Outcome::run:
      HistoryText::validate(text, pane->screen.modes().bracketed_paste);
      runCommand(pane_id, text);
      // Every pane's suggestions know the command at once, without asking the history again.
      std::erase(prompt_history_, text);
      prompt_history_.insert(prompt_history_.begin(), std::string{text});
      if (prompt_history_.size() > prompt_history_limit) {
        prompt_history_.pop_back();
      }

      break;
    case prompt::Outcome::answer: {
      HistoryText::validate(text.empty() ? std::string_view{" "} : text, false);
      std::string answer{text};

      answer.push_back('\r');
      input(pane_id, answer);
      break;
    }
    case prompt::Outcome::bytes:
      input(pane_id, text);
      break;
    default:
      break;
    }
  }

  void Session::beginCompletion(std::uint64_t pane_id, prompt::Line& line, shell::Syntax syntax) {
    const auto* pane = findPane(pane_id);
    const auto& text = line.editor().text();
    auto context = prompt::completionContext(text.view(), text.cursor(), syntax);
    if (pane == nullptr || !context) {
      return;
    }

    // A command's spec comes from the runtime, for the commands this pane's shell runs; while
    // it is on its way, Tab waits for it and completes once it arrives.
    const ebnf::command_spec* spec = nullptr;

    if (!context->command_position && !pane->shell.remote && ready_) {
      switch (specState(pane_id, context->command)) {
      case SpecState::available: {
        // An alias completes as the words it stands for: `gst -` as `git status -`.
        const auto& aliases = command_checks_[pane_id].aliases;
        if (const auto alias = aliases.find(context->command); alias != aliases.end()) {
          std::vector<std::string> words;

          for (auto rest = std::string_view{alias->second}; !rest.empty();) {
            const auto end = rest.find(' ');
            if (end != 0) {
              words.emplace_back(rest.substr(0, end));
            }

            rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
          }

          if (!words.empty()) {
            context->command = words.front().substr(words.front().rfind('/') + 1);
            context->words.insert(context->words.begin(), words.begin() + 1, words.end());
            spec = prompt_specs_.find(words.front());
          }
        } else {
          spec = prompt_specs_.find(context->command);
        }

        break;
      }
      case SpecState::pending:
        spec_completions_.insert_or_assign(pane_id, std::string{text.view()});
        return;
      case SpecState::unavailable:
        break;
      }
    }

    auto completion = prompt::complete(*context, spec, prompt_specs_.scratch(), line.recent());
    const auto wants = [&](std::string_view provider) {
      return std::ranges::find(completion.providers, provider) != completion.providers.end();
    };

    auto partial = std::string_view{context->partial};
    if (partial.starts_with(completion.provider_prefix)) {
      partial.remove_prefix(completion.provider_prefix.size());
    }

    std::vector<std::uint64_t> requests;
    // A remote shell's files, branches and commands are on its host: only the spec's own
    // choices apply there.
    const bool local = !pane->shell.remote;
    if (ready_ && local && (wants("file") || wants("directory"))) {
      const auto slash = partial.rfind('/');
      const auto directory = slash == std::string_view::npos ? std::string_view{} : partial.substr(0, slash + 1);
      std::string root{directory.starts_with('/') ? std::string_view{} : std::string_view{pane->cwd}};
      if (!directory.starts_with('/') && !root.ends_with('/')) {
        root.push_back('/');
      }

      root.append(directory);
      while (root.size() > 1 && root.ends_with('/')) {
        root.pop_back();
      }

      const auto query = slash == std::string_view::npos ? partial : partial.substr(slash + 1);
      if (root.starts_with('/') && query.size() <= 64) {
        const FindPaths find{.request_id = nextRequest(), .root = root, .query = query, .kind = wants("file") ? PathKindFilter::any : PathKindFilter::directories, .limit = 50};

        try {
          send(find);
          requests.push_back(find.request_id);
          path_completions_.emplace(find.request_id, PathCompletion{pane_id, completion.provider_prefix + std::string{directory}, std::string{query}});
        } catch (const std::length_error&) {
        }
      }
    }

    // Commands on the shell's PATH, branches, SSH hosts and make targets come from the runtime.
    // A spec's @ref is a branch name as far as the editor completes it.
    static constexpr std::array<std::pair<std::string_view, CompletionProvider>, 10> providers{{{"command", CompletionProvider::command}, {"branch", CompletionProvider::branch}, {"ssh_host", CompletionProvider::ssh_host}, {"make_target", CompletionProvider::make_target}, {"remote", CompletionProvider::remote}, {"stash", CompletionProvider::stash}, {"process", CompletionProvider::process}, {"just_recipe", CompletionProvider::just_recipe}, {"package_script", CompletionProvider::package_script}, {"compose_service", CompletionProvider::compose_service}}};

    for (const auto& [name, provider] : providers) {
      const bool asked = context->command_position ? provider == CompletionProvider::command : wants(name) || (provider == CompletionProvider::branch && wants("ref"));
      if (!ready_ || !local || !asked || partial.size() > 256) {
        continue;
      }

      const CompleteWords request{.request_id = nextRequest(), .pane_id = pane_id, .provider = provider, .prefix = partial};

      try {
        send(request);
        requests.push_back(request.request_id);
        path_completions_.emplace(request.request_id, PathCompletion{pane_id, completion.provider_prefix, std::string{partial}});
      } catch (const std::length_error&) {
      }
    }

    // The heading names where the choices come from.
    const auto label = [&]() -> std::string {
      if (context->command_position) {
        return "commands";
      }

      static constexpr std::array<std::pair<std::string_view, std::string_view>, 12> sources{{{"branch", "branches · git"}, {"ref", "branches · git"}, {"remote", "remotes · git"}, {"stash", "stashes · git"}, {"ssh_host", "hosts · ssh"}, {"make_target", "targets · make"}, {"just_recipe", "recipes · just"}, {"package_script", "scripts · package.json"}, {"compose_service", "services · compose"}, {"process", "processes"}, {"file", "files"}, {"directory", "directories"}}};

      for (const auto& [provider, name] : sources) {
        if (wants(provider)) {
          return std::string{name};
        }
      }

      return context->command;
    };

    line.offer(std::move(completion.choices), context->replace_begin, context->replace_end, std::move(requests), syntax.dialect, label());
  }

  std::size_t Session::StringHash::operator()(std::string_view text) const noexcept {
    return std::hash<std::string_view>{}(text);
  }

  auto Session::commandChecks(const Pane<Memory>& pane) -> CommandChecks& {
    auto& checks = command_checks_[pane.id];
    if (checks.commands != pane.shell.commands || checks.directory != std::string_view{pane.cwd} || checks.words.size() > 512 || checks.listed.size() > 64) {
      checks.commands = pane.shell.commands;
      checks.directory.assign(pane.cwd);
      checks.words.clear();
      checks.listed.clear();
      checks.specs.clear();
      checks.aliases.clear();
    }

    return checks;
  }

  void Session::learnCommand(std::uint64_t pane_id, std::string_view line, shell::Dialect dialect) {
    std::vector<prompt::Style> styles(line.size());

    prompt::classify(line, styles, shell::Syntax{.dialect = dialect});
    const auto start = std::ranges::find_if(styles, [](prompt::Style style) {
      return style == prompt::Style::command || style == prompt::Style::pending;
    });
    if (start == styles.end()) {
      return;
    }

    const auto first = static_cast<std::size_t>(start - styles.begin());
    auto end = first;

    while (end < styles.size() && styles[end] == styles[first]) {
      ++end;
    }

    auto& checks = command_checks_[pane_id];
    if (checks.learned.size() >= 256) {
      checks.learned.clear();
    }

    const auto word = line.substr(first, end - first);

    checks.learned.emplace(word);
    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      known->second = CommandPresence::found;
    }
  }

  auto Session::specState(std::uint64_t pane_id, std::string_view command) -> SpecState {
    if (command.empty() || command.size() > 64) {
      return SpecState::unavailable;
    }

    const auto* pane = findPane(pane_id);
    if (pane == nullptr) {
      return SpecState::unavailable;
    }

    auto& checks = commandChecks(*pane);
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      return known->second;
    }

    // An alias's spec is its command's: the digest of the one held for what it last stood for.
    const auto target = checks.alias_targets.find(command);
    const RequestCommandSpec request{.request_id = nextRequest(), .pane_id = pane_id, .command = command, .known_digest = prompt_specs_.digest(target == checks.alias_targets.end() ? command : std::string_view{target->second})};

    try {
      send(request);
    } catch (const std::exception&) {
      checks.specs.emplace(std::string{command}, SpecState::unavailable);
      return SpecState::unavailable;
    }

    checks.specs.emplace(std::string{command}, SpecState::pending);
    spec_requests_.emplace(request.request_id, CommandRequest{pane_id, std::string{command}});
    return SpecState::pending;
  }

  void Session::listCommands(std::uint64_t pane_id, std::string_view prefix, std::span<const CompletionWord> words) {
    const auto checks = command_checks_.find(pane_id);
    if (checks == command_checks_.end()) {
      return;
    }

    const auto known = checks->second.words.find(prefix);
    if (known == checks->second.words.end() || known->second != CommandPresence::pending) {
      return;
    }

    auto& listed = checks->second.listed[std::string{prefix}];

    listed.clear();
    listed.reserve(words.size());
    for (const auto& word : words) {
      listed.emplace_back(word.text);
    }
  }

  std::optional<Change> Session::failPromptRequest(std::uint64_t request_id) {
    if (const auto checked = command_requests_.find(request_id); checked != command_requests_.end()) {
      return settleCommand(checked, CommandPresence::unknown);
    }

    if (const auto request = spec_requests_.find(request_id); request != spec_requests_.end()) {
      const auto [pane_id, command] = std::move(request->second);

      spec_requests_.erase(request);
      if (const auto checks = command_checks_.find(pane_id); checks != command_checks_.end()) {
        if (const auto known = checks->second.specs.find(command); known != checks->second.specs.end() && known->second == SpecState::pending) {
          known->second = SpecState::unavailable;
        }
      }

      spec_completions_.erase(pane_id);
      return Change::none;
    }

    if (const auto pending = path_completions_.find(request_id); pending != path_completions_.end()) {
      const auto pane_id = pending->second.pane_id;

      path_completions_.erase(pending);
      const auto line = lines_.find(pane_id);
      if (line == lines_.end() || !line->second.line.receive(request_id, {}, true)) {
        return Change::none;
      }

      changed_pane_ = pane_id;
      return Change::terminal;
    }

    return std::nullopt;
  }

  void Session::failPromptRequests() noexcept {
    try {
      while (!command_requests_.empty()) {
        static_cast<void>(failPromptRequest(command_requests_.begin()->first));
      }

      while (!spec_requests_.empty()) {
        static_cast<void>(failPromptRequest(spec_requests_.begin()->first));
      }

      while (!path_completions_.empty()) {
        static_cast<void>(failPromptRequest(path_completions_.begin()->first));
      }
    } catch (const std::exception&) {
      // A menu that could not settle keeps its choices; no answer is waited for any more.
      command_requests_.clear();
      spec_requests_.clear();
      spec_completions_.clear();
      path_completions_.clear();
    }
  }

  Change Session::settleCommand(typename std::unordered_map<std::uint64_t, CommandRequest>::iterator request, CommandPresence presence) {
    const auto [pane_id, word] = std::move(request->second);

    command_requests_.erase(request);
    // A command the shell runs may have a spec: asked now, it is there by the first Tab.
    if (presence == CommandPresence::found && word.find('/') == std::string::npos) {
      static_cast<void>(specState(pane_id, word));
    }

    const auto checks = command_checks_.find(pane_id);
    if (checks == command_checks_.end()) {
      return Change::none;
    }

    const auto known = checks->second.words.find(word);
    if (known == checks->second.words.end() || known->second != CommandPresence::pending) {
      return Change::none;
    }

    known->second = presence;
    changed_pane_ = pane_id;
    return Change::terminal;
  }

}
