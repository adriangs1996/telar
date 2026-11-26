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
import telar.base.memory.allocators;
import telar.tbc;

namespace telar::gui::features::prompt {

  namespace {

    using Checks = ds::Map<std::uint64_t, CommandChecks, Memory>;

    // What a pane remembers of its shell's commands starts over past these.
    constexpr std::size_t checked_words_limit = 512;
    constexpr std::size_t listed_prefixes_limit = 64;
    constexpr std::size_t learned_limit = 256;
    constexpr std::size_t alias_targets_limit = 256;

    // Words longer than these are not commands or names anyone types: the runtime is not asked
    // about them.
    constexpr std::size_t longest_word = 256;
    constexpr std::size_t longest_name = 64;
    // The most matches a path search returns.
    constexpr std::uint16_t path_matches = 50;

    // The pane's checks, made empty in `memory` the first time. Valid until the next pane's are made.
    tbc::mut_a<CommandChecks> checksOf(tbc::mut_a<Checks> all, tbc::mut_a<Memory> memory, std::uint64_t pane_id) {
      if (auto* found = all.findMut(pane_id)) {
        return *found;
      }

      static_cast<void>(all.insert(pane_id, CommandChecks{memory}));
      auto* inserted = all.findMut(pane_id);
      if (inserted == nullptr) {
        throw std::logic_error{"Inserted command checks missing"};
      }

      return *inserted;
    }

    // What the pane learned of its shell's commands, forgotten after each command and change of
    // directory: either may change which commands run.
    tbc::mut_a<CommandChecks> commandChecks(tbc::mut_a<Checks> all, tbc::mut_a<Memory> memory, const Commands& commands) {
      auto& checks = checksOf(all, memory, commands.pane_id);
      if (checks.commands != commands.commands || checks.directory.view() != commands.directory || checks.words.size() > checked_words_limit || checks.listed.size() > listed_prefixes_limit) {
        checks.commands = commands.commands;
        checks.directory.assign(commands.directory);
        checks.words.clear();
        checks.listed.clear();
        checks.specs.clear();
        checks.aliases.clear();
      }

      return checks;
    }

    // Pane `pane_id`'s line, or null.
    PaneLine* lineOf(Lines& lines, std::uint64_t pane_id) noexcept {
      auto* found = lines.findMut(pane_id);

      return found == nullptr ? nullptr : &found->getMut();
    }

    // Keeps every command an answer listed under the word it was asked for, while what the pane
    // knows of its commands is still the one it asked from.
    void listCommands(State& state, std::uint64_t pane_id, std::string_view prefix, std::span<const CompletionWord> words) {
      auto* checks = state.command_checks.findMut(pane_id);
      if (checks == nullptr) {
        return;
      }

      const auto* known = checks->words.find(prefix);
      if (known == nullptr || *known != CommandPresence::pending) {
        return;
      }

      auto& memory = state.memory;
      ds::Vec<Name, Memory> listed{memory};

      listed.reserve(words.size());
      for (const auto& word : words) {
        listed.emplace(memory, word.text);
      }

      static_cast<void>(checks->listed.assign(Name{memory, prefix}, std::move(listed)));
    }

    // The question `request_id` about a command, answered: it no longer waits.
    tbc::val_a<Settled> take(ds::Map<std::uint64_t, CommandRequest, Memory>& requests, std::uint64_t request_id, CommandPresence presence) {
      auto request = requests.remove(request_id);
      auto& [pane_id, word] = request.getMut();

      return {.pane_id = pane_id, .word = std::move(word), .presence = presence};
    }

  }

  CommandChecks::CommandChecks(Memory& memory)
      : directory(memory),
        words(memory),
        listed(memory),
        learned(memory),
        specs(memory),
        aliases(memory),
        alias_targets(memory) {}

  PaneLine::PaneLine(Memory& memory, std::uint64_t pane, Keymap keymap)
      : line(memory, keymap),
        pane_id(pane),
        jumps(memory) {}

  CompletionPlan::Question::Question(Memory& memory)
      : root(memory),
        query(memory),
        base(memory) {}

  CompletionPlan::CompletionPlan(Memory& memory)
      : context(memory),
        completion(memory),
        label(memory),
        questions(memory) {}

  State::State(tbc::mut_a<Memory> allocator)
      : memory(allocator),
        specs(allocator),
        scratch(allocator),
        history(allocator),
        completions(allocator),
        command_requests(allocator),
        command_checks(allocator),
        spec_requests(allocator),
        spec_completions(allocator),
        command_root(allocator) {}

  // ---- lines ------------------------------------------------------------------------------------

  tbc::val_a<Opened> open(State& state, tbc::mut_a<Lines> lines, std::uint64_t pane_id, Keymap keymap) {
    const bool wants_history = state.history.empty();
    auto* found = lines.findMut(pane_id);
    const bool inserted = found == nullptr;

    if (inserted) {
      auto& memory = state.memory;

      static_cast<void>(lines.insert(pane_id, ds::makeBox<PaneLine>(memory, memory, pane_id, keymap)));
      found = lines.findMut(pane_id);
    }

    if (found == nullptr) {
      throw std::logic_error{"Inserted prompt line missing"};
    }

    auto& line = found->getMut();

    line.line.setKeymap(keymap);
    return {.line = line, .wants_history = inserted && wants_history};
  }

  void forget(State& state, Lines& lines, std::uint64_t pane_id) noexcept {
    const auto other = [pane_id](const auto&, const auto& value) {
      return value.pane_id != pane_id;
    };

    static_cast<void>(state.command_requests.retain(other));
    static_cast<void>(state.spec_requests.retain(other));
    static_cast<void>(state.completions.retain(other));
    static_cast<void>(state.command_checks.remove(pane_id));
    static_cast<void>(state.spec_completions.remove(pane_id));
    static_cast<void>(lines.remove(pane_id));
  }

  // ---- keys and text ----------------------------------------------------------------------------

  static_assert(runtime::config::prompt_action_names.size() == static_cast<std::size_t>(Action::insert_mode) + 1);

  ds::Option<Action> bound(const KeyPress& key, const Editor& editor, const PromptConfiguration& configuration) {
    using Chord = runtime::config::KeyChord;
    const bool normal = editor.keymap() == Keymap::vim && editor.mode() != Mode::insert;
    const auto named = [&] -> ds::Option<Chord::Key> {
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
    auto& history = state.history;
    // Copied first: `command` may be one of the entries the history drops.
    Name entry{state.memory, command};

    static_cast<void>(history.retain([&entry](const Name& kept) {
      return kept.view() != entry.view();
    }));

    history.insert(0, std::move(entry));
    history.truncate(State::history_limit);
  }

  void committed(PaneLine& line, std::string_view command) {
    line.line.committed(command);
  }

  void insert(State& state, PaneLine& line, std::string_view text) {
    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_control = 0x7f;
    // U+0080 to U+009F, the C1 controls, are C2 80 to C2 9F in UTF-8.
    constexpr unsigned char extended_control_lead = 0xc2;
    constexpr unsigned char last_extended_control = 0x9f;

    Name clean{state.memory};

    clean.reserve(text.size());
    for (std::size_t index = 0; index < text.size(); ++index) {
      const auto byte = text[index];
      const auto value = static_cast<unsigned char>(byte);
      if (value == extended_control_lead && index + 1 < text.size() && static_cast<unsigned char>(text[index + 1]) <= last_extended_control) {
        ++index;
        continue;
      }

      if (value >= first_printable || byte == '\n' || byte == '\t') {
        clean.push(value == delete_control ? ' ' : byte);
      }
    }

    line.line.insertText(clean.view());
    state.written = line.pane_id;
  }

  void write(State& state, PaneLine& line, std::string_view command) {
    line.line.write(command);
    state.written = line.pane_id;
  }

  bool replace(State& state, Lines& lines, const LineWord& word, std::string_view text) {
    auto* line = lineOf(lines, word.pane_id);
    if (line == nullptr) {
      return false;
    }

    auto& typed = line->line;
    const auto& current = typed.editor().text();
    const auto end = word.begin + word.text.size();
    if (current.cursor() != end || current.view().substr(word.begin, word.text.size()) != word.text) {
      return false;
    }

    typed.replaceText(word.begin, end, text);
    state.written = word.pane_id;
    return true;
  }

  ds::Option<std::uint64_t> takeWrite(State& state) noexcept {
    const auto written = std::exchange(state.written, 0);

    return written == 0 ? ds::none : ds::Option{written};
  }

  bool BetweenCommands::now(const PaneLine& line, std::int64_t now) noexcept {
    return line.ended && std::chrono::nanoseconds{now - *line.ended} < limit;
  }

  ds::Option<Outcome> follow(PaneLine& line, const PaneShell& previous, const PaneShell& current, std::int64_t now) {
    auto& typed = line.line;

    if (current.phase != ShellPhase::running || current.echo) {
      typed.clearSecret();
    }

    // An answer ends with the line its program read: the program is gone, or reads keys raw
    // or unseen.
    if (current.phase != ShellPhase::running || !current.canonical || !current.echo) {
      line.forwarding = false;
    }

    // A command ended, or another began: whether the queue may run is known from here, though
    // the shell may run its hooks before its prompt is back.
    if (current.commands != previous.commands) {
      line.succeeded = current.status == 0;
    } else if (current.phase == ShellPhase::running && previous.phase != ShellPhase::running) {
      line.succeeded = false;
    }

    if (current.phase != ShellPhase::unknown) {
      line.ended.reset();
    } else if (current.commands != previous.commands) {
      line.ended = now;
    }

    if (previous.phase == ShellPhase::prompt || current.phase != ShellPhase::prompt) {
      return ds::none;
    }

    return typed.promptReturned(std::exchange(line.succeeded, false));
  }

  void useClipboard(tbc::mut_a<PaneLine> line, tbc::val_a<Clipboard> clipboard) {
    line.line.editorMut().setClipboard(std::move(clipboard));
  }

  // ---- the commands the shell runs --------------------------------------------------------------

  ds::Option<CommandPresence> presence(State& state, const Commands& commands, std::string_view word) {
    if (word.empty() || word.size() > longest_word) {
      return CommandPresence::unknown;
    }

    auto& checks = commandChecks(state.command_checks, state.memory, commands);
    if (checks.learned.contains(word)) {
      return CommandPresence::found;
    }

    if (const auto* known = checks.words.find(word)) {
      return *known;
    }

    if (word.contains('/')) {
      return ds::none;
    }

    for (const auto& entry : checks.listed) {
      if (!word.starts_with(entry.key.view())) {
        continue;
      }

      const auto listed = std::ranges::any_of(entry.value, [word](const Name& command) {
        return command.view() == word;
      });

      const auto presence = listed ? CommandPresence::found : CommandPresence::missing;

      static_cast<void>(checks.words.insert(Name{state.memory, word}, presence));
      return presence;
    }

    return ds::none;
  }

  tbc::val_b<ds::Option<CommandQuery>> ask(tbc::mut_b<Name> root, const Commands& commands, tbc::val_b<std::string_view> word, std::uint64_t request_id, bool reads_directories) {
    const auto slash = word.rfind('/');
    if (slash == std::string_view::npos) {
      return CompleteWords{.request_id = request_id, .pane_id = commands.pane_id, .provider = CompletionProvider::command, .prefix = word};
    }

    // A command named by its path: the executables of its directory, read where the shell runs.
    if (reads_directories) {
      if (word.size() > longest_word || slash + 1 == word.size()) {
        return ds::none;
      }

      return CompleteWords{.request_id = request_id, .pane_id = commands.pane_id, .provider = CompletionProvider::executable, .prefix = word};
    }

    // A command named by its path: a file there, from the directory the shell is in.
    root.assign(word.starts_with('/') ? std::string_view{} : commands.directory);
    if (!word.starts_with('/')) {
      root.push('/');
    }

    root.append(word.substr(0, slash));
    while (root.size() > 1 && root.view().ends_with('/')) {
      root.truncate(root.size() - 1);
    }

    const auto name = word.substr(slash + 1);
    if (name.empty() || name.size() > longest_name || !root.view().starts_with('/')) {
      return ds::none;
    }

    return FindPaths{.request_id = request_id, .root = root.view(), .query = name, .kind = PathKindFilter::any, .limit = path_matches};
  }

  void asked(State& state, std::uint64_t pane_id, std::string_view word, std::uint64_t request_id, bool sent) {
    auto& memory = state.memory;
    auto& checks = checksOf(state.command_checks, state.memory, pane_id);

    if (!sent) {
      static_cast<void>(checks.words.insert(Name{memory, word}, CommandPresence::unknown));
      return;
    }

    static_cast<void>(checks.words.insert(Name{memory, word}, CommandPresence::pending));
    static_cast<void>(state.command_requests.insert(request_id, CommandRequest{.pane_id = pane_id, .word = Name{memory, word}}));
  }

  void learn(State& state, std::uint64_t pane_id, std::string_view command, shell::Dialect dialect) {
    auto& memory = state.memory;
    ds::Vec<Style, Memory> styles{memory};
    ds::Vec<shell::Token, Memory> tokens{memory};

    styles.resize(command.size());
    classify(command, styles.viewMut(), tokens, shell::Syntax{.dialect = dialect});
    const auto classes = styles.view();
    const auto start = std::ranges::find_if(classes, [](Style style) {
      return style == Style::command || style == Style::pending;
    });
    if (start == classes.end()) {
      return;
    }

    const auto first = static_cast<std::size_t>(start - classes.begin());
    auto end = first;

    while (end < classes.size() && classes[end] == classes[first]) {
      ++end;
    }

    auto& checks = checksOf(state.command_checks, state.memory, pane_id);
    if (checks.learned.size() >= learned_limit) {
      checks.learned.clear();
    }

    const auto word = command.substr(first, end - first);

    static_cast<void>(checks.learned.insert(Name{memory, word}, true));
    if (auto* known = checks.words.findMut(word)) {
      *known = CommandPresence::found;
    }
  }

  tbc::val_a<ds::Option<Settled>> settles(State& state, const CompletionWords& message) {
    const auto* checked = state.command_requests.find(message.request_id);
    if (checked == nullptr) {
      return ds::none;
    }

    const auto found = std::ranges::any_of(message.words, [&](const CompletionWord& word) {
      return word.text == checked->word.view();
    });

    if (!message.truncated) {
      listCommands(state, checked->pane_id, checked->word.view(), message.words);
    }

    const auto unnamed = message.truncated ? CommandPresence::unknown : CommandPresence::missing;

    return take(state.command_requests, message.request_id, found ? CommandPresence::found : unnamed);
  }

  tbc::val_a<ds::Option<Settled>> settles(State& state, const PathResults& message) {
    const auto* checked = state.command_requests.find(message.request_id);
    if (checked == nullptr) {
      return ds::none;
    }

    const auto word = checked->word.view();
    const auto name = word.substr(word.rfind('/') + 1);
    const auto found = std::ranges::any_of(message.matches, [&](const PathMatch& match) {
      return match.kind != PathKind::directory && match.path == name;
    });

    const auto unnamed = message.truncated ? CommandPresence::unknown : CommandPresence::missing;

    return take(state.command_requests, message.request_id, found ? CommandPresence::found : unnamed);
  }

  namespace {

    // The word `settled` names is marked in `all`; true when it was waited for.
    bool settleIn(Checks& all, const Settled& settled) {
      auto* checks = all.findMut(settled.pane_id);
      if (checks == nullptr) {
        return false;
      }

      auto* known = checks->words.findMut(settled.word.view());
      if (known == nullptr || *known != CommandPresence::pending) {
        return false;
      }

      *known = settled.presence;
      return true;
    }

  }

  bool settle(State& state, const Settled& settled) {
    return settleIn(state.command_checks, settled);
  }

  // ---- completion specs -------------------------------------------------------------------------

  ds::Option<SpecState> spec(State& state, const Commands& commands, std::string_view command) {
    if (command.empty() || command.size() > longest_name) {
      return SpecState::unavailable;
    }

    const auto& checks = commandChecks(state.command_checks, state.memory, commands);
    if (const auto* known = checks.specs.find(command)) {
      return *known;
    }

    return ds::none;
  }

  tbc::val_b<RequestCommandSpec> askSpec(const State& state, std::uint64_t pane_id, tbc::val_b<std::string_view> command, std::uint64_t request_id) noexcept {
    // An alias's spec is its command's: the digest of the one held for what it last stood for.
    const auto* checks = state.command_checks.find(pane_id);
    auto named = command;

    if (checks != nullptr) {
      if (const auto* target = checks->alias_targets.find(command)) {
        named = target->view();
      }
    }

    return {.request_id = request_id, .pane_id = pane_id, .command = command, .known_digest = state.specs.digest(named)};
  }

  void askedSpec(State& state, std::uint64_t pane_id, std::string_view command, std::uint64_t request_id, bool sent) {
    auto& memory = state.memory;
    auto& checks = checksOf(state.command_checks, state.memory, pane_id);

    if (!sent) {
      static_cast<void>(checks.specs.insert(Name{memory, command}, SpecState::unavailable));
      return;
    }

    static_cast<void>(checks.specs.insert(Name{memory, command}, SpecState::pending));
    static_cast<void>(state.spec_requests.insert(request_id, CommandRequest{.pane_id = pane_id, .word = Name{memory, command}}));
  }

  ds::Option<std::uint64_t> receive(State& state, const CommandSpec& message) {
    const auto request = state.spec_requests.remove(message.request_id);
    if (!request) {
      return ds::none;
    }

    auto& memory = state.memory;
    const auto pane_id = request->pane_id;
    const auto command = request->word.view();
    // An alias's spec is the one of the command it stands for, kept under that command's name.
    const auto expansion = message.command == command ? message.expansion : std::string_view{};
    const auto target = expansion.empty() ? command : expansion.substr(0, expansion.find(' '));
    auto& specs = state.specs;
    auto available = SpecState::unavailable;

    if (message.state == CommandSpecState::available && message.command == command) {
      available = specs.install(target, message.digest, message.source) ? SpecState::available : SpecState::unavailable;
    } else if (message.state == CommandSpecState::unchanged && specs.find(target) != nullptr && specs.digest(target) == message.digest) {
      available = SpecState::available;
    }

    auto& checks = checksOf(state.command_checks, state.memory, pane_id);
    if (auto* known = checks.specs.findMut(command)) {
      *known = available;
    }

    if (available == SpecState::available && !expansion.empty()) {
      static_cast<void>(checks.aliases.assign(Name{memory, command}, Name{memory, expansion}));
      if (checks.alias_targets.size() >= alias_targets_limit) {
        checks.alias_targets.clear();
      }

      static_cast<void>(checks.alias_targets.assign(Name{memory, command}, Name{memory, target}));
    }

    return pane_id;
  }

  bool resume(State& state, Lines& lines, std::uint64_t pane_id) {
    auto& waiting = state.spec_completions;
    const auto* found = waiting.find(pane_id);
    const auto* line = lineOf(lines, pane_id);
    if (found == nullptr || line == nullptr) {
      return false;
    }

    const bool same = found->view() == line->line.editor().text().view();

    static_cast<void>(waiting.remove(pane_id));
    return same;
  }

  // ---- completion -------------------------------------------------------------------------------

  tbc::val_a<ds::Option<CompletionContext>> completing(State& state, const PaneLine& line, shell::Dialect dialect) {
    const auto& text = line.line.editor().text();

    return completionContext(state.memory, text.view(), text.cursor(), shell::Syntax{.dialect = dialect});
  }

  void awaitSpec(State& state, const PaneLine& line) {
    static_cast<void>(state.spec_completions.assign(line.pane_id, Name{state.memory, line.line.editor().text().view()}));
  }

  namespace {

    // An alias completes as the words it stands for: `gst -` as `git status -`. The spec of the
    // command it names, or null.
    tbc::val_b<const ebnf::command_spec*> aliasSpec(tbc::ref_b<Specs> specs, tbc::mut_a<Memory> memory, std::string_view alias, tbc::mut_a<CompletionContext> context) {
      ds::Vec<Name, Memory> words{memory};

      for (auto rest = alias; !rest.empty();) {
        const auto end = rest.find(' ');
        if (end != 0) {
          words.emplace(memory, rest.substr(0, end));
        }

        rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
      }

      if (words.empty()) {
        return nullptr;
      }

      const auto named = words[0].view();

      context.command.assign(named.substr(named.rfind('/') + 1));
      const auto* found = specs.find(named);

      for (std::size_t index = 1; index < words.size(); ++index) {
        static_cast<void>(context.words.insert(index - 1, std::move(words.atMut(index))));
      }

      return found;
    }

    bool wants(const Completion& completion, std::string_view provider) {
      return std::ranges::any_of(completion.providers, [provider](const Name& name) {
        return name.view() == provider;
      });
    }

    // Files, or only directories, under the directory `partial` types, which a relative one reads
    // from `directory`.
    void askPaths(tbc::mut_a<CompletionPlan> result, std::string_view directory, tbc::mut_a<Memory> memory, std::string_view partial) {
      const auto& completion = result.completion;
      const auto slash = partial.rfind('/');
      const auto typed = slash == std::string_view::npos ? std::string_view{} : partial.substr(0, slash + 1);
      CompletionPlan::Question question{memory};

      question.root.assign(typed.starts_with('/') ? std::string_view{} : directory);
      if (!typed.starts_with('/') && !question.root.view().ends_with('/')) {
        question.root.push('/');
      }

      question.root.append(typed);
      while (question.root.size() > 1 && question.root.view().ends_with('/')) {
        question.root.truncate(question.root.size() - 1);
      }

      const auto query = slash == std::string_view::npos ? partial : partial.substr(slash + 1);
      if (question.root.view().starts_with('/') && query.size() <= longest_name) {
        question.paths = true;
        question.kind = wants(completion, "file") ? PathKindFilter::any : PathKindFilter::directories;
        question.query.assign(query);
        question.base.assign(completion.provider_prefix.view());
        question.base.append(typed);
        result.questions.push(std::move(question));
      }
    }

    // The entries of the one directory `partial` names, which the runtime reads where the shell
    // runs and writes back as typed: files, or only directories.
    void askDirectory(tbc::mut_a<CompletionPlan> result, tbc::mut_a<Memory> memory, std::string_view partial, CompletionProvider provider) {
      if (partial.size() > longest_word) {
        return;
      }

      CompletionPlan::Question question{memory};

      question.provider = provider;
      question.query.assign(partial);
      question.base.assign(result.completion.provider_prefix.view());
      result.questions.push(std::move(question));
    }

    // Commands on the shell's PATH, branches, SSH hosts and make targets come from the runtime.
    // A spec's @ref is a revision, which a runtime that `names_references` lists with tags; an
    // older one lists branches for it.
    void askProviders(tbc::mut_a<CompletionPlan> result, tbc::mut_a<Memory> memory, bool command_position, std::string_view partial, bool names_references) {
      static constexpr ds::Array<std::pair<std::string_view, CompletionProvider>, 11> providers{{{"command", CompletionProvider::command}, {"branch", CompletionProvider::branch}, {"ref", CompletionProvider::reference}, {"ssh_host", CompletionProvider::ssh_host}, {"make_target", CompletionProvider::make_target}, {"remote", CompletionProvider::remote}, {"stash", CompletionProvider::stash}, {"process", CompletionProvider::process}, {"just_recipe", CompletionProvider::just_recipe}, {"package_script", CompletionProvider::package_script}, {"compose_service", CompletionProvider::compose_service}}};

      const auto& completion = result.completion;
      const bool references = wants(completion, "ref");

      for (const auto& [name, provider] : providers) {
        const bool listed = wants(completion, name) && (provider != CompletionProvider::reference || names_references);
        // An older runtime lists branches for a revision.
        const bool branches = provider == CompletionProvider::branch && references && !names_references;
        const bool wanted = command_position ? provider == CompletionProvider::command : listed || branches;
        if (!wanted || partial.size() > longest_word) {
          continue;
        }

        CompletionPlan::Question question{memory};

        question.provider = provider;
        question.query.assign(partial);
        question.base.assign(completion.provider_prefix.view());
        result.questions.push(std::move(question));
      }
    }

    // The heading names where the choices come from.
    tbc::val_b<std::string_view> sourceLabel(tbc::ref_b<CompletionContext> context, const Completion& completion) {
      static constexpr ds::Array<std::pair<std::string_view, std::string_view>, 12> sources{{{"branch", "branches · git"}, {"ref", "refs · git"}, {"remote", "remotes · git"}, {"stash", "stashes · git"}, {"ssh_host", "hosts · ssh"}, {"make_target", "targets · make"}, {"just_recipe", "recipes · just"}, {"package_script", "scripts · package.json"}, {"compose_service", "services · compose"}, {"process", "processes"}, {"file", "files"}, {"directory", "directories"}}};

      if (context.command_position) {
        return "commands";
      }

      for (const auto& [provider, name] : sources) {
        if (wants(completion, provider)) {
          return name;
        }
      }

      return context.command.view();
    }

  }

  tbc::val_a<CompletionPlan> plan(State& state, const PaneLine& line, tbc::val_a<CompletionContext> context, const CompletionSources& sources) {
    const auto& [specified, asks, directory, dialect, reads_directories, reads_references] = sources;
    auto& memory = state.memory;
    const auto& specs = state.specs;
    const ebnf::command_spec* found = nullptr;

    if (specified) {
      const auto* checks = state.command_checks.find(line.pane_id);
      const auto* alias = checks == nullptr ? nullptr : checks->aliases.find(context.command.view());

      found = alias == nullptr ? specs.find(context.command.view()) : aliasSpec(specs, memory, alias->view(), context);
    }

    CompletionPlan result{memory};

    result.completion = complete(memory, context, found, state.scratch.lend(), line.line.recent(), shell::Syntax{.dialect = dialect});

    auto partial = context.partial.view();
    if (partial.starts_with(result.completion.provider_prefix.view())) {
      partial.remove_prefix(result.completion.provider_prefix.size());
    }

    // A remote shell's files, branches and commands are on its host: only the spec's own choices
    // apply there.
    const bool files = wants(result.completion, "file");

    if (asks && reads_directories && context.command_position && partial.contains('/')) {
      // A command named by its path: the executables and directories there.
      askDirectory(result, memory, partial, CompletionProvider::executable);
    } else if (asks && reads_directories && (files || wants(result.completion, "directory"))) {
      askDirectory(result, memory, partial, files ? CompletionProvider::path : CompletionProvider::directory);
      askProviders(result, memory, context.command_position, partial, reads_references);
    } else if (asks) {
      if (files || wants(result.completion, "directory")) {
        askPaths(result, directory, memory, partial);
      }

      askProviders(result, memory, context.command_position, partial, reads_references);
    }

    const auto label = sourceLabel(context, result.completion);

    result.label.assign(label);
    result.dialect = dialect;
    result.context = std::move(context);
    return result;
  }

  std::size_t questions(const CompletionPlan& plan) noexcept {
    return plan.questions.size();
  }

  std::variant<FindPaths, CompleteWords> request(const CompletionPlan& plan, Asking asking) noexcept {
    const auto& question = plan.questions[asking.index];
    if (question.paths) {
      return FindPaths{.request_id = asking.request_id, .root = question.root.view(), .query = question.query.view(), .kind = question.kind, .limit = path_matches};
    }

    return CompleteWords{.request_id = asking.request_id, .pane_id = asking.pane_id, .provider = question.provider, .prefix = question.query.view()};
  }

  void sent(CompletionPlan& plan, std::size_t index, std::uint64_t request_id) noexcept {
    plan.questions.atMut(index).request_id = request_id;
  }

  void offer(tbc::mut_a<State> state, PaneLine& line, tbc::val_a<CompletionPlan> plan) {
    const auto pane_id = line.pane_id;
    auto& completions = state.completions;
    ds::Vec<std::uint64_t, Memory> requests{state.memory};

    for (auto& question : plan.questions.viewMut()) {
      if (question.request_id != 0) {
        requests.push(question.request_id);
        static_cast<void>(completions.insert(question.request_id, PathCompletion{.pane_id = pane_id, .base = std::move(question.base), .query = std::move(question.query)}));
      }
    }

    const auto& context = plan.context;

    line.line.offer(std::move(plan.completion.choices), {.begin = context.replace_begin, .end = context.replace_end}, std::move(requests), plan.dialect, plan.label.view());
  }

  ds::Option<std::uint64_t> receive(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, const CompletionWords& message) {
    const auto pending = state.completions.remove(message.request_id);
    if (!pending) {
      return ds::none;
    }

    const auto& [pane_id, base, query] = *pending;
    auto* line = lineOf(lines, pane_id);
    if (line == nullptr) {
      return 0;
    }

    auto& memory = state.memory;
    Choices words{memory};

    words.reserve(message.words.size());
    for (const auto& word : message.words) {
      Name text = base.clone();

      text.append(word.text);
      // A directory's path ends with its slash; Tab goes on into it instead of ending the word.
      words.push(Choice{.text = std::move(text), .description = Name{memory, word.description}, .directory = word.text.ends_with('/')});
    }

    line->line.receive(message.request_id, std::move(words), message.truncated);
    return pane_id;
  }

  ds::Option<std::uint64_t> receive(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, const PathResults& message) {
    const auto pending = state.completions.remove(message.request_id);
    if (!pending) {
      return ds::none;
    }

    const auto& [pane_id, base, query] = *pending;
    auto* line = lineOf(lines, pane_id);
    if (line == nullptr) {
      return 0;
    }

    // The shell completes one directory at a time: children of the root that start with what was
    // typed, not the deeper matches the search also finds.
    auto& memory = state.memory;
    Choices paths{memory};

    for (const auto& match : message.matches) {
      // Directories arrive with their trailing slash.
      const bool directory = match.kind == PathKind::directory;
      const auto name = directory ? match.path.substr(0, match.path.size() - 1) : match.path;
      if (!name.contains('/') && name.starts_with(query.view())) {
        Name text = base.clone();

        text.append(match.path);
        paths.push(Choice{.text = std::move(text), .description = Name{memory}, .directory = directory});
      }
    }

    line->line.receive(message.request_id, std::move(paths), message.truncated);
    return pane_id;
  }

  bool asksAgain(Lines& lines, std::uint64_t pane_id) noexcept {
    auto* line = find(lines, pane_id);

    return line != nullptr && line->line.takeAskAgain();
  }

  // ---- requests that fail -----------------------------------------------------------------------

  ds::Option<std::uint64_t> fail(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, std::uint64_t request_id) {
    // A history query that failed is asked again.
    if (request_id != 0 && request_id == state.history_request) {
      state.history_request = 0;
      return 0;
    }

    if (state.command_requests.contains(request_id)) {
      const auto settled = take(state.command_requests, request_id, CommandPresence::unknown);

      return settleIn(state.command_checks, settled) ? settled.pane_id : 0;
    }

    if (const auto request = state.spec_requests.remove(request_id)) {
      const auto pane_id = request->pane_id;

      if (auto* checks = state.command_checks.findMut(pane_id)) {
        if (auto* known = checks->specs.findMut(request->word.view()); known != nullptr && *known == SpecState::pending) {
          *known = SpecState::unavailable;
        }
      }

      static_cast<void>(state.spec_completions.remove(pane_id));
      return 0;
    }

    if (const auto pending = state.completions.remove(request_id)) {
      const auto pane_id = pending->pane_id;
      auto* line = lineOf(lines, pane_id);
      if (line == nullptr || !line->line.receive(request_id, Choices{state.memory}, true)) {
        return 0;
      }

      return pane_id;
    }

    return ds::none;
  }

  void failAll(State& state, Lines& lines) noexcept {
    state.history_request = 0;
    try {
      while (!state.command_requests.empty()) {
        const auto request_id = (*state.command_requests.begin()).key;

        static_cast<void>(fail(state, lines, request_id));
      }

      while (!state.spec_requests.empty()) {
        const auto request_id = (*state.spec_requests.begin()).key;

        static_cast<void>(fail(state, lines, request_id));
      }

      while (!state.completions.empty()) {
        const auto request_id = (*state.completions.begin()).key;

        static_cast<void>(fail(state, lines, request_id));
      }
    } catch (const std::exception&) {
      // A menu that could not settle keeps its choices; no answer is waited for any more.
      state.command_requests.clear();
      state.spec_requests.clear();
      state.spec_completions.clear();
      state.completions.clear();
    }
  }

  // ---- the history the suggestions read --------------------------------------------------------

  bool historyAsked(const State& state) noexcept {
    return state.history_request != 0;
  }

  bool historyWanted(const State& state) noexcept {
    return !state.history_loaded && state.history_request == 0;
  }

  QueryHistory historyQuery(std::uint64_t request_id) noexcept {
    return {.request_id = request_id, .author = HistoryAuthorFilter::human, .distinct = true, .limit = State::history_limit};
  }

  void askedHistory(State& state, std::uint64_t request_id) noexcept {
    state.history_request = request_id;
  }

  bool receive(State& state, const HistoryResults& message) {
    auto& request = state.history_request;
    if (message.request_id != request || request == 0) {
      return false;
    }

    auto& history = state.history;

    request = 0;
    state.history_loaded = true;
    history.clear();
    for (const auto& entry : message.entries) {
      if (!entry.command_truncated && !entry.command.empty()) {
        history.emplace(state.memory, entry.command);
      }
    }

    return true;
  }

  // ---- the command block selected from the line -------------------------------------------------

  ds::Option<std::size_t> selectedBlock(const Lines& lines, std::uint64_t pane_id) noexcept {
    const auto* found = lines.find(pane_id);

    return found == nullptr ? ds::none : std::as_const(**found).block;
  }

  ds::Option<std::size_t> selectedBlock(const PaneLine& line) noexcept {
    return line.block;
  }

  void selectBlock(PaneLine& line, ds::Option<std::size_t> index, bool by_pointer) noexcept {
    line.chord = 0;
    line.block_by_pointer = index && by_pointer;
    line.block = index;
  }

  void moveBlock(PaneLine& line, ds::Option<std::size_t> index) noexcept {
    line.block = index;
    if (!index) {
      line.block_by_pointer = false;
      line.chord = 0;
    }
  }

  bool blockByPointer(const PaneLine& line) noexcept {
    return line.block && line.block_by_pointer;
  }

  void beginChord(PaneLine& line, char first) noexcept {
    line.chord = first;
  }

  char takeChord(PaneLine& line) noexcept {
    return std::exchange(line.chord, 0);
  }

  void recordJump(PaneLine& line, std::uint64_t here) {
    constexpr std::size_t maximum_jumps = 64;
    auto& jumps = line.jumps;
    auto& jump = line.jump;

    jumps.truncate(std::min(jump, jumps.size()));
    if (jumps.empty() || jumps.back() != here) {
      jumps.push(here);
    }

    if (jumps.size() > maximum_jumps) {
      static_cast<void>(jumps.remove(0));
    }

    jump = jumps.size();
  }

  ds::Option<std::uint64_t> jump(PaneLine& line, std::uint64_t here, bool back) {
    auto& jumps = line.jumps;
    auto& current = line.jump;

    if (back) {
      if (current == 0 || jumps.empty()) {
        return ds::none;
      }

      if (current == jumps.size()) {
        // The first step back remembers where it left, for Ctrl-I to return to.
        if (jumps.back() != here) {
          jumps.push(here);
        }

        current = jumps.size() - 1;
      }

      --current;
    } else {
      if (current + 1 >= jumps.size()) {
        return ds::none;
      }

      ++current;
    }

    return jumps[current];
  }

}
