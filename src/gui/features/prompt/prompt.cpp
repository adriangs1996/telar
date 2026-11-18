module telar.gui.features.prompt;

import std;

import telar.config.client;
import telar.config.runtime;
import telar.ebnf.matcher;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.shell.syntax;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::prompt {

  namespace {

    // What the pane learned of its shell's commands, forgotten after each command and change of
    // directory: either may change which commands run.
    CommandChecks& commandChecks(State& state, const Commands& commands) {
      auto& checks = Access::commandChecks(state)[commands.pane_id];
      if (checks.commands != commands.commands || checks.directory != commands.directory || checks.words.size() > 512 || checks.listed.size() > 64) {
        checks.commands = commands.commands;
        checks.directory.assign(commands.directory);
        checks.words.clear();
        checks.listed.clear();
        checks.specs.clear();
        checks.aliases.clear();
      }

      return checks;
    }

    // Keeps every command an answer listed under the word it was asked for, while what the pane
    // knows of its commands is still the one it asked from.
    void listCommands(State& state, std::uint64_t pane_id, std::string_view prefix, std::span<const CompletionWord> words) {
      auto& all = Access::commandChecks(state);
      const auto checks = all.find(pane_id);
      if (checks == all.end()) {
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

    // The question about a command, answered: it no longer waits.
    Settled take(State& state, std::unordered_map<std::uint64_t, CommandRequest>::iterator request, CommandPresence presence) {
      auto [pane_id, word] = std::move(request->second);

      Access::commandRequests(state).erase(request);
      return {.pane_id = pane_id, .word = std::move(word), .presence = presence};
    }

  }

  std::size_t StringHash::operator()(std::string_view text) const noexcept {
    return std::hash<std::string_view>{}(text);
  }

  // ---- lines ------------------------------------------------------------------------------------

  Opened open(State& state, std::uint64_t pane_id, Keymap keymap) {
    auto [found, inserted] = Access::lines(state).try_emplace(pane_id, pane_id, keymap);

    Access::line(found->second).setKeymap(keymap);
    return {.line = found->second, .wants_history = inserted && Access::history(state).empty()};
  }

  void forget(State& state, std::uint64_t pane_id) noexcept {
    const auto owned = [pane_id](const auto& entry) {
      return entry.second.pane_id == pane_id;
    };

    std::erase_if(Access::commandRequests(state), owned);
    std::erase_if(Access::specRequests(state), owned);
    std::erase_if(Access::completions(state), owned);
    Access::commandChecks(state).erase(pane_id);
    Access::specCompletions(state).erase(pane_id);
    Access::lines(state).erase(pane_id);
  }

  // ---- keys and text ----------------------------------------------------------------------------

  static_assert(runtime::config::prompt_action_names.size() == static_cast<std::size_t>(Action::insert_mode) + 1);

  ds::Option<Action> bound(const KeyPress& key, const Editor& editor, const PromptConfiguration& configuration) {
    using Chord = runtime::config::KeyChord;
    const bool normal = editor.keymap() == Keymap::vim && editor.mode() != Mode::insert;
    const auto named = [&]() -> ds::Option<Chord::Key> {
      switch (key.key) {
      case Key::character:
        return Chord::Key::character;
      case Key::enter:
        return Chord::Key::enter;
      case Key::backspace:
        return Chord::Key::backspace;
      case Key::delete_forward:
        return Chord::Key::erase;
      case Key::left:
        return Chord::Key::left;
      case Key::right:
        return Chord::Key::right;
      case Key::up:
        return Chord::Key::up;
      case Key::down:
        return Chord::Key::down;
      case Key::home:
        return Chord::Key::home;
      case Key::end:
        return Chord::Key::end;
      case Key::tab:
        return Chord::Key::tab;
      case Key::backtab:
        return Chord::Key::back_tab;
      case Key::escape:
        return Chord::Key::escape;
      }

      return ds::none;
    }();
    if (!named) {
      return ds::none;
    }

    unsigned modifiers = (key.modifiers.control ? static_cast<unsigned>(Chord::Modifier::control) : 0U) | (key.modifiers.alt ? static_cast<unsigned>(Chord::Modifier::alt) : 0U);

    // A shifted character is its own character; Shift counts only with named keys.
    if (*named != Chord::Key::character && key.modifiers.shift) {
      modifiers |= static_cast<unsigned>(Chord::Modifier::shift);
    }

    const auto character = *named == Chord::Key::character ? KeyCharacter::pack(key.character) : 0U;

    for (const auto& binding : configuration.bindings) {
      if (binding.normal == normal && binding.key == static_cast<std::uint8_t>(*named) && binding.modifiers == modifiers && binding.character == character) {
        return static_cast<Action>(binding.action);
      }
    }

    return ds::none;
  }

  void remember(State& state, std::string_view command) {
    auto& history = Access::history(state);

    std::erase(history, command);
    history.insert(history.begin(), std::string{command});
    if (history.size() > State::history_limit) {
      history.pop_back();
    }
  }

  void insert(State& state, PaneLine& line, std::string_view text) {
    std::string clean;

    clean.reserve(text.size());
    for (const auto byte : text) {
      const auto value = static_cast<unsigned char>(byte);
      if (value >= 0x20 || byte == '\n' || byte == '\t') {
        clean.push_back(value == 0x7f ? ' ' : byte);
      }
    }

    Access::line(line).insertText(clean);
    Access::written(state) = Access::paneId(line);
  }

  void write(State& state, PaneLine& line, std::string_view command) {
    auto& text = Access::line(line).editorMut().textMut();

    text.assign(command);
    text.moveTo(text.size());
    Access::written(state) = Access::paneId(line);
  }

  bool replace(State& state, std::uint64_t pane_id, std::size_t begin, std::string_view word, std::string_view text) {
    auto* line = find(state, pane_id);
    if (line == nullptr) {
      return false;
    }

    auto& typed = Access::line(*line);
    const auto& current = typed.editor().text();
    const auto end = begin + word.size();
    if (current.cursor() != end || current.view().substr(begin, word.size()) != word) {
      return false;
    }

    typed.replaceText(begin, end, text);
    Access::written(state) = pane_id;
    return true;
  }

  ds::Option<std::uint64_t> takeWrite(State& state) noexcept {
    const auto written = std::exchange(Access::written(state), 0);

    return written == 0 ? ds::none : ds::Option{written};
  }

  ds::Option<Outcome> follow(PaneLine& line, const PaneShell& previous, const PaneShell& current) {
    auto& typed = Access::line(line);

    if (current.phase != ShellPhase::running || current.echo) {
      typed.clearSecret();
    }

    if (previous.phase != ShellPhase::running || current.phase != ShellPhase::prompt) {
      return ds::none;
    }

    return typed.promptReturned(current.commands != previous.commands && current.status == 0);
  }

  void useClipboard(PaneLine& line, Clipboard clipboard) {
    Access::line(line).editorMut().setClipboard(std::move(clipboard));
  }

  // ---- the commands the shell runs --------------------------------------------------------------

  ds::Option<CommandPresence> presence(State& state, const Commands& commands, std::string_view word) {
    if (word.empty() || word.size() > 256) {
      return CommandPresence::unknown;
    }

    auto& checks = commandChecks(state, commands);
    if (checks.learned.contains(word)) {
      return CommandPresence::found;
    }

    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      return known->second;
    }

    if (word.find('/') == std::string_view::npos) {
      for (const auto& [prefix, listed] : checks.listed) {
        if (word.starts_with(prefix)) {
          const auto presence = std::ranges::find(listed, word) != listed.end() ? CommandPresence::found : CommandPresence::missing;

          checks.words.emplace(std::string{word}, presence);
          return presence;
        }
      }
    }

    return ds::none;
  }

  ds::Option<CommandQuery> ask(State& state, const Commands& commands, std::string_view word, std::uint64_t request_id) {
    const auto slash = word.rfind('/');
    if (slash == std::string_view::npos) {
      return CompleteWords{.request_id = request_id, .pane_id = commands.pane_id, .provider = CompletionProvider::command, .prefix = word};
    }

    // A command named by its path: a file there, from the directory the shell is in.
    auto& root = Access::commandRoot(state);

    root.assign(word.starts_with('/') ? std::string_view{} : commands.directory);
    if (!word.starts_with('/')) {
      root.push_back('/');
    }

    root.append(word.substr(0, slash));
    while (root.size() > 1 && root.ends_with('/')) {
      root.pop_back();
    }

    const auto name = word.substr(slash + 1);
    if (name.empty() || name.size() > 64 || !root.starts_with('/')) {
      return ds::none;
    }

    return FindPaths{.request_id = request_id, .root = root, .query = name, .kind = PathKindFilter::any, .limit = 50};
  }

  void asked(State& state, std::uint64_t pane_id, std::string_view word, std::uint64_t request_id, bool sent) {
    auto& checks = Access::commandChecks(state)[pane_id];
    if (!sent) {
      checks.words.emplace(std::string{word}, CommandPresence::unknown);
      return;
    }

    checks.words.emplace(std::string{word}, CommandPresence::pending);
    Access::commandRequests(state).emplace(request_id, CommandRequest{pane_id, std::string{word}});
  }

  void learn(State& state, std::uint64_t pane_id, std::string_view command, shell::Dialect dialect) {
    std::vector<Style> styles(command.size());

    classify(command, styles, shell::Syntax{.dialect = dialect});
    const auto start = std::ranges::find_if(styles, [](Style style) {
      return style == Style::command || style == Style::pending;
    });
    if (start == styles.end()) {
      return;
    }

    const auto first = static_cast<std::size_t>(start - styles.begin());
    auto end = first;

    while (end < styles.size() && styles[end] == styles[first]) {
      ++end;
    }

    auto& checks = Access::commandChecks(state)[pane_id];
    if (checks.learned.size() >= 256) {
      checks.learned.clear();
    }

    const auto word = command.substr(first, end - first);

    checks.learned.emplace(word);
    if (const auto known = checks.words.find(word); known != checks.words.end()) {
      known->second = CommandPresence::found;
    }
  }

  ds::Option<Settled> settles(State& state, const CompletionWords& message) {
    auto& requests = Access::commandRequests(state);
    const auto checked = requests.find(message.request_id);
    if (checked == requests.end()) {
      return ds::none;
    }

    const auto found = std::ranges::any_of(message.words, [&](const CompletionWord& word) {
      return word.text == checked->second.word;
    });

    if (!message.truncated) {
      listCommands(state, checked->second.pane_id, checked->second.word, message.words);
    }

    return take(state, checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown
                                                                                   : CommandPresence::missing);
  }

  ds::Option<Settled> settles(State& state, const PathResults& message) {
    auto& requests = Access::commandRequests(state);
    const auto checked = requests.find(message.request_id);
    if (checked == requests.end()) {
      return ds::none;
    }

    const auto name = std::string_view{checked->second.word}.substr(checked->second.word.rfind('/') + 1);
    const auto found = std::ranges::any_of(message.matches, [&](const PathMatch& match) {
      return match.kind != PathKind::directory && match.path == name;
    });

    return take(state, checked, found ? CommandPresence::found : message.truncated ? CommandPresence::unknown
                                                                                   : CommandPresence::missing);
  }

  bool settle(State& state, const Settled& settled) {
    auto& all = Access::commandChecks(state);
    const auto checks = all.find(settled.pane_id);
    if (checks == all.end()) {
      return false;
    }

    const auto known = checks->second.words.find(settled.word);
    if (known == checks->second.words.end() || known->second != CommandPresence::pending) {
      return false;
    }

    known->second = settled.presence;
    return true;
  }

  // ---- completion specs -------------------------------------------------------------------------

  ds::Option<SpecState> spec(State& state, const Commands& commands, std::string_view command) {
    if (command.empty() || command.size() > 64) {
      return SpecState::unavailable;
    }

    auto& checks = commandChecks(state, commands);
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      return known->second;
    }

    return ds::none;
  }

  RequestCommandSpec askSpec(const State& state, std::uint64_t pane_id, std::string_view command, std::uint64_t request_id) noexcept {
    // An alias's spec is its command's: the digest of the one held for what it last stood for.
    const auto& all = Access::commandChecks(state);
    const auto checks = all.find(pane_id);
    auto named = command;

    if (checks != all.end()) {
      if (const auto target = checks->second.alias_targets.find(command); target != checks->second.alias_targets.end()) {
        named = target->second;
      }
    }

    return {.request_id = request_id, .pane_id = pane_id, .command = command, .known_digest = Access::specs(state).digest(named)};
  }

  void askedSpec(State& state, std::uint64_t pane_id, std::string_view command, std::uint64_t request_id, bool sent) {
    auto& checks = Access::commandChecks(state)[pane_id];
    if (!sent) {
      checks.specs.emplace(std::string{command}, SpecState::unavailable);
      return;
    }

    checks.specs.emplace(std::string{command}, SpecState::pending);
    Access::specRequests(state).emplace(request_id, CommandRequest{pane_id, std::string{command}});
  }

  ds::Option<std::uint64_t> receive(State& state, const CommandSpec& message) {
    auto& requests = Access::specRequests(state);
    const auto request = requests.find(message.request_id);
    if (request == requests.end()) {
      return ds::none;
    }

    const auto [pane_id, command] = std::move(request->second);

    requests.erase(request);
    // An alias's spec is the one of the command it stands for, kept under that command's name.
    const auto expansion = message.command == command ? message.expansion : std::string_view{};
    const auto target = expansion.empty() ? std::string_view{command} : expansion.substr(0, expansion.find(' '));
    auto& specs = Access::specs(state);
    auto available = SpecState::unavailable;

    if (message.state == CommandSpecState::available && message.command == command) {
      available = specs.install(target, message.digest, message.source) ? SpecState::available : SpecState::unavailable;
    } else if (message.state == CommandSpecState::unchanged && specs.find(target) != nullptr && specs.digest(target) == message.digest) {
      available = SpecState::available;
    }

    auto& checks = Access::commandChecks(state)[pane_id];
    if (const auto known = checks.specs.find(command); known != checks.specs.end()) {
      known->second = available;
    }

    if (available == SpecState::available && !expansion.empty()) {
      checks.aliases.insert_or_assign(command, std::string{expansion});
      if (checks.alias_targets.size() >= 256) {
        checks.alias_targets.clear();
      }

      checks.alias_targets.insert_or_assign(command, std::string{target});
    }

    return pane_id;
  }

  bool resume(State& state, std::uint64_t pane_id) {
    auto& waiting = Access::specCompletions(state);
    const auto found = waiting.find(pane_id);
    const auto* line = find(state, pane_id);
    if (found == waiting.end() || line == nullptr) {
      return false;
    }

    const bool same = found->second == Access::line(*line).editor().text().view();

    waiting.erase(found);
    return same;
  }

  // ---- completion -------------------------------------------------------------------------------

  ds::Option<CompletionContext> completing(const PaneLine& line, shell::Dialect dialect) {
    const auto& text = Access::line(line).editor().text();

    return completionContext(text.view(), text.cursor(), shell::Syntax{.dialect = dialect});
  }

  void awaitSpec(State& state, const PaneLine& line) {
    Access::specCompletions(state).insert_or_assign(Access::paneId(line), std::string{Access::line(line).editor().text().view()});
  }

  CompletionPlan plan(State& state, const PaneLine& line, CompletionContext context, bool specified, bool asks, std::string_view directory, shell::Dialect dialect) {
    const auto pane_id = Access::paneId(line);
    auto& specs = Access::specs(state);
    const ebnf::command_spec* found = nullptr;

    if (specified) {
      // An alias completes as the words it stands for: `gst -` as `git status -`.
      const auto& aliases = Access::commandChecks(state)[pane_id].aliases;
      if (const auto alias = aliases.find(context.command); alias != aliases.end()) {
        std::vector<std::string> words;

        for (auto rest = std::string_view{alias->second}; !rest.empty();) {
          const auto end = rest.find(' ');
          if (end != 0) {
            words.emplace_back(rest.substr(0, end));
          }

          rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
        }

        if (!words.empty()) {
          context.command = words.front().substr(words.front().rfind('/') + 1);
          context.words.insert(context.words.begin(), words.begin() + 1, words.end());
          found = specs.find(words.front());
        }
      } else {
        found = specs.find(context.command);
      }
    }

    CompletionPlan result;
    auto& completion = Access::completion(result);

    completion = complete(context, found, specs.scratch(), Access::line(line).recent());
    const auto wants = [&](std::string_view provider) {
      return std::ranges::find(completion.providers, provider) != completion.providers.end();
    };

    auto partial = std::string_view{context.partial};
    if (partial.starts_with(completion.provider_prefix)) {
      partial.remove_prefix(completion.provider_prefix.size());
    }

    auto& questions = Access::questions(result);
    auto& count = Access::count(result);

    // A remote shell's files, branches and commands are on its host: only the spec's own choices
    // apply there.
    if (asks && (wants("file") || wants("directory"))) {
      const auto slash = partial.rfind('/');
      const auto typed = slash == std::string_view::npos ? std::string_view{} : partial.substr(0, slash + 1);
      auto& question = questions[count];

      question.root.assign(typed.starts_with('/') ? std::string_view{} : directory);
      if (!typed.starts_with('/') && !question.root.ends_with('/')) {
        question.root.push_back('/');
      }

      question.root.append(typed);
      while (question.root.size() > 1 && question.root.ends_with('/')) {
        question.root.pop_back();
      }

      const auto query = slash == std::string_view::npos ? partial : partial.substr(slash + 1);
      if (question.root.starts_with('/') && query.size() <= 64) {
        question.paths = true;
        question.kind = wants("file") ? PathKindFilter::any : PathKindFilter::directories;
        question.query.assign(query);
        question.base = completion.provider_prefix + std::string{typed};
        ++count;
      }
    }

    // Commands on the shell's PATH, branches, SSH hosts and make targets come from the runtime.
    // A spec's @ref is a branch name as far as the editor completes it.
    static constexpr std::array<std::pair<std::string_view, CompletionProvider>, 10> providers{{{"command", CompletionProvider::command}, {"branch", CompletionProvider::branch}, {"ssh_host", CompletionProvider::ssh_host}, {"make_target", CompletionProvider::make_target}, {"remote", CompletionProvider::remote}, {"stash", CompletionProvider::stash}, {"process", CompletionProvider::process}, {"just_recipe", CompletionProvider::just_recipe}, {"package_script", CompletionProvider::package_script}, {"compose_service", CompletionProvider::compose_service}}};

    for (const auto& [name, provider] : providers) {
      const bool wanted = context.command_position ? provider == CompletionProvider::command : wants(name) || (provider == CompletionProvider::branch && wants("ref"));
      if (!asks || !wanted || partial.size() > 256) {
        continue;
      }

      auto& question = questions[count++];

      question.provider = provider;
      question.query.assign(partial);
      question.base = completion.provider_prefix;
    }

    // The heading names where the choices come from.
    const auto label = [&]() -> std::string {
      if (context.command_position) {
        return "commands";
      }

      static constexpr std::array<std::pair<std::string_view, std::string_view>, 12> sources{{{"branch", "branches · git"}, {"ref", "branches · git"}, {"remote", "remotes · git"}, {"stash", "stashes · git"}, {"ssh_host", "hosts · ssh"}, {"make_target", "targets · make"}, {"just_recipe", "recipes · just"}, {"package_script", "scripts · package.json"}, {"compose_service", "services · compose"}, {"process", "processes"}, {"file", "files"}, {"directory", "directories"}}};

      for (const auto& [provider, name] : sources) {
        if (wants(provider)) {
          return std::string{name};
        }
      }

      return context.command;
    };

    Access::label(result) = label();
    Access::dialect(result) = dialect;
    Access::context(result) = std::move(context);
    return result;
  }

  std::size_t questions(const CompletionPlan& plan) noexcept {
    return Access::count(plan);
  }

  std::variant<FindPaths, CompleteWords> request(const CompletionPlan& plan, std::size_t index, std::uint64_t pane_id, std::uint64_t request_id) noexcept {
    const auto& question = Access::questions(plan)[index];
    if (question.paths) {
      return FindPaths{.request_id = request_id, .root = question.root, .query = question.query, .kind = question.kind, .limit = 50};
    }

    return CompleteWords{.request_id = request_id, .pane_id = pane_id, .provider = question.provider, .prefix = question.query};
  }

  void sent(CompletionPlan& plan, std::size_t index, std::uint64_t request_id) noexcept {
    Access::questions(plan)[index].request_id = request_id;
  }

  void offer(State& state, PaneLine& line, CompletionPlan plan) {
    const auto pane_id = Access::paneId(line);
    auto& completions = Access::completions(state);
    std::vector<std::uint64_t> requests;

    for (auto& question : std::span{Access::questions(plan)}.first(Access::count(plan))) {
      if (question.request_id != 0) {
        requests.push_back(question.request_id);
        completions.emplace(question.request_id, PathCompletion{pane_id, std::move(question.base), std::move(question.query)});
      }
    }

    const auto& context = Access::context(plan);

    Access::line(line).offer(std::move(Access::completion(plan).choices), context.replace_begin, context.replace_end, std::move(requests), Access::dialect(plan), std::move(Access::label(plan)));
  }

  ds::Option<std::uint64_t> receive(State& state, const CompletionWords& message) {
    auto& completions = Access::completions(state);
    const auto pending = completions.find(message.request_id);
    if (pending == completions.end()) {
      return ds::none;
    }

    const auto [pane_id, base, query] = std::move(pending->second);

    completions.erase(pending);
    auto* line = find(state, pane_id);
    if (line == nullptr) {
      return 0;
    }

    std::vector<Choice> words;

    for (const auto& word : message.words) {
      words.push_back({.text = base + std::string{word.text}, .description = std::string{word.description}});
    }

    Access::line(*line).receive(message.request_id, words, message.truncated);
    return pane_id;
  }

  ds::Option<std::uint64_t> receive(State& state, const PathResults& message) {
    auto& completions = Access::completions(state);
    const auto pending = completions.find(message.request_id);
    if (pending == completions.end()) {
      return ds::none;
    }

    const auto [pane_id, base, query] = std::move(pending->second);

    completions.erase(pending);
    auto* line = find(state, pane_id);
    if (line == nullptr) {
      return 0;
    }

    // The shell completes one directory at a time: children of the root that start with what was
    // typed, not the deeper matches the search also finds.
    std::vector<Choice> paths;

    for (const auto& match : message.matches) {
      // Directories arrive with their trailing slash.
      const bool directory = match.kind == PathKind::directory;
      const auto name = directory ? match.path.substr(0, match.path.size() - 1) : match.path;
      if (name.find('/') == std::string_view::npos && name.starts_with(query)) {
        paths.push_back({.text = base + std::string{match.path}, .directory = directory});
      }
    }

    Access::line(*line).receive(message.request_id, paths, message.truncated);
    return pane_id;
  }

  // ---- requests that fail -----------------------------------------------------------------------

  ds::Option<std::uint64_t> fail(State& state, std::uint64_t request_id) {
    auto& commands = Access::commandRequests(state);
    if (const auto checked = commands.find(request_id); checked != commands.end()) {
      const auto settled = take(state, checked, CommandPresence::unknown);

      return settle(state, settled) ? settled.pane_id : 0;
    }

    auto& specs = Access::specRequests(state);
    if (const auto request = specs.find(request_id); request != specs.end()) {
      const auto [pane_id, command] = std::move(request->second);

      specs.erase(request);
      auto& all = Access::commandChecks(state);
      if (const auto checks = all.find(pane_id); checks != all.end()) {
        if (const auto known = checks->second.specs.find(command); known != checks->second.specs.end() && known->second == SpecState::pending) {
          known->second = SpecState::unavailable;
        }
      }

      Access::specCompletions(state).erase(pane_id);
      return 0;
    }

    auto& completions = Access::completions(state);
    if (const auto pending = completions.find(request_id); pending != completions.end()) {
      const auto pane_id = pending->second.pane_id;

      completions.erase(pending);
      auto* line = find(state, pane_id);
      if (line == nullptr || !Access::line(*line).receive(request_id, {}, true)) {
        return 0;
      }

      return pane_id;
    }

    return ds::none;
  }

  void failAll(State& state) noexcept {
    auto& commands = Access::commandRequests(state);
    auto& specs = Access::specRequests(state);
    auto& completions = Access::completions(state);

    try {
      while (!commands.empty()) {
        static_cast<void>(fail(state, commands.begin()->first));
      }

      while (!specs.empty()) {
        static_cast<void>(fail(state, specs.begin()->first));
      }

      while (!completions.empty()) {
        static_cast<void>(fail(state, completions.begin()->first));
      }
    } catch (const std::exception&) {
      // A menu that could not settle keeps its choices; no answer is waited for any more.
      commands.clear();
      specs.clear();
      Access::specCompletions(state).clear();
      completions.clear();
    }
  }

  // ---- the history the suggestions read --------------------------------------------------------

  bool historyAsked(const State& state) noexcept {
    return Access::historyRequest(state) != 0;
  }

  QueryHistory historyQuery(std::uint64_t request_id) noexcept {
    return {.request_id = request_id, .author = HistoryAuthorFilter::human, .distinct = true, .limit = State::history_limit};
  }

  void askedHistory(State& state, std::uint64_t request_id) noexcept {
    Access::historyRequest(state) = request_id;
  }

  bool receive(State& state, const HistoryResults& message) {
    auto& request = Access::historyRequest(state);
    if (message.request_id != request || request == 0) {
      return false;
    }

    auto& history = Access::history(state);

    request = 0;
    history.clear();
    for (const auto& entry : message.entries) {
      if (!entry.command_truncated && !entry.command.empty()) {
        history.emplace_back(entry.command);
      }
    }

    return true;
  }

  // ---- the command block selected from the line -------------------------------------------------

  ds::Option<std::size_t> selectedBlock(const State& state, std::uint64_t pane_id) noexcept {
    const auto& lines = Access::lines(state);
    const auto found = lines.find(pane_id);

    return found == lines.end() ? ds::none : Access::block(found->second);
  }

  ds::Option<std::size_t> selectedBlock(const PaneLine& line) noexcept {
    return Access::block(line);
  }

  void selectBlock(PaneLine& line, ds::Option<std::size_t> index, ds::Option<std::uint32_t> live_prompt) noexcept {
    auto& block = Access::block(line);

    Access::chord(line) = 0;
    if (!index) {
      block.reset();
      return;
    }

    if (!block) {
      Access::livePrompt(line) = live_prompt;
    }

    block = index;
  }

  ds::Option<std::uint32_t> livePrompt(const State& state, std::uint64_t pane_id) noexcept {
    const auto& lines = Access::lines(state);
    const auto found = lines.find(pane_id);

    return found == lines.end() ? ds::none : Access::livePrompt(found->second);
  }

  void beginChord(PaneLine& line, char first) noexcept {
    Access::chord(line) = first;
  }

  char takeChord(PaneLine& line) noexcept {
    return std::exchange(Access::chord(line), 0);
  }

  void recordJump(PaneLine& line, std::uint64_t here) {
    constexpr std::size_t maximum_jumps = 64;
    auto& jumps = Access::jumps(line);
    auto& jump = Access::jump(line);

    jumps.resize(std::min(jump, jumps.size()));
    if (jumps.empty() || jumps.back() != here) {
      jumps.push_back(here);
    }

    if (jumps.size() > maximum_jumps) {
      jumps.erase(jumps.begin());
    }

    jump = jumps.size();
  }

  ds::Option<std::uint64_t> jump(PaneLine& line, std::uint64_t here, bool back) {
    auto& jumps = Access::jumps(line);
    auto& at = Access::jump(line);

    if (back) {
      if (at == 0 || jumps.empty()) {
        return ds::none;
      }

      if (at == jumps.size()) {
        // The first step back remembers where it left, for Ctrl-I to return to.
        if (jumps.back() != here) {
          jumps.push_back(here);
        }

        at = jumps.size() - 1;
      }

      --at;
    } else {
      if (at + 1 >= jumps.size()) {
        return ds::none;
      }

      ++at;
    }

    return jumps[at];
  }

}
