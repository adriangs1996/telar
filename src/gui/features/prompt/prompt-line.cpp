module telar.gui.features.prompt;

import std;

import telar.shell.syntax;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  namespace {

    // The word the menu completes, as the shell reads it now: none when the cursor left it. It
    // borrows only `memory`, so the menu can change while it is read.
    tbc::val_a<ds::Option<CompletionContext>> menuContext(tbc::mut_a<Memory> memory, const Editor& editor, const Menu& menu) {
      const auto& text = editor.text();
      auto context = completionContext(memory, text.view(), text.cursor(), shell::Syntax{.dialect = menu.dialect});
      if (context && context->replace_begin != menu.begin) {
        context.reset();
      }

      return context;
    }

    bool takesSuggestion(const KeyPress& key) noexcept {
      return (key.key == Key::right && !key.modifiers.alt && !key.modifiers.shift) || key.key == Key::end || (key.key == Key::character && key.modifiers.control && (key.character == 'e' || key.character == 'f'));
    }

    bool takesSuggestedWord(const KeyPress& key) noexcept {
      return (key.key == Key::character && key.modifiers.alt && key.character == 'f') || (key.key == Key::right && key.modifiers.alt);
    }

    enum class MenuStep : std::uint8_t {
      none,
      forward,
      backward,
    };

    // Where a key moves the menu's selection: Tab, Down and Ctrl-N forward, Shift-Tab, Up and
    // Ctrl-P back.
    MenuStep menuStep(const KeyPress& key) noexcept {
      const bool control = key.key == Key::character && key.modifiers.control;
      if ((key.key == Key::tab && !key.modifiers.shift) || key.key == Key::down || (control && key.character == 'n')) {
        return MenuStep::forward;
      }

      if (key.key == Key::backtab || key.key == Key::tab || key.key == Key::up || (control && key.character == 'p')) {
        return MenuStep::backward;
      }

      return MenuStep::none;
    }

    // `text` without a character its end cuts short.
    std::string_view wholeCharacters(std::string_view text) noexcept { // NOLINT(bugprone-exception-escape): substr is given an offset within the text, which cannot throw
      constexpr unsigned char continuation_mask = 0xc0;
      constexpr unsigned char continuation = 0x80;
      auto start = text.size();

      while (start != 0 && (static_cast<unsigned char>(text[start - 1]) & continuation_mask) == continuation) {
        --start;
      }

      if (start == 0) {
        return text;
      }

      // The lead byte says how long its character is: 110xxxxx two bytes, 1110xxxx three, 11110xxx four.
      const auto lead = static_cast<unsigned char>(text[start - 1]);
      constexpr unsigned char two_bytes = 0xc0;
      constexpr unsigned char three_bytes = 0xe0;
      constexpr unsigned char four_bytes = 0xf0;
      auto length = 4U;

      if (lead < two_bytes) {
        length = 1;
      } else if (lead < three_bytes) {
        length = 2;
      } else if (lead < four_bytes) {
        length = 3;
      }

      return text.size() - (start - 1) < length ? text.substr(0, start - 1) : text;
    }

    // The quote a word leaves open at its end, wherever it opened (`--file="My Do`); 0 when none
    // is.
    char openQuote(std::string_view word) noexcept {
      char quote = 0;

      for (std::size_t index = 0; index < word.size(); ++index) {
        const char byte = word[index];
        if (quote == 0 && (byte == '"' || byte == '\'')) {
          quote = byte;
        } else if (quote == byte) {
          quote = 0;
        } else if (byte == '\\' && quote != '\'') {
          // Outside quotes and inside double ones, a backslash takes the byte after it.
          ++index;
        }
      }

      return quote;
    }

    // `text` as it reads inside the `quote` a word left open, appended to `word`; false when it
    // cannot be written there, as a single quote inside single quotes.
    bool appendQuoted(ds::String<Memory>& word, std::string_view text, char quote, shell::Dialect dialect) {
      const std::string_view escaped = dialect == shell::Dialect::fish ? "\"\\$" : "\"\\$`";

      for (const auto byte : text) {
        if (byte == quote && quote == '\'') {
          return false;
        }

        if (quote == '"' && escaped.contains(byte)) {
          word.push('\\');
        }

        word.push(byte);
      }

      return true;
    }

    // The first word of `rest`, with the blanks before it and through a slash that ends it.
    std::string_view nextWord(std::string_view rest) {
      const auto start = rest.find_first_not_of(' ');
      const auto end = rest.find_first_of(" /", start == std::string_view::npos ? 0 : start);

      return rest.substr(0, end == std::string_view::npos ? rest.size() : end + (rest[end] == '/' ? 1 : 0));
    }

  }

  Line::Line(tbc::mut_a<Memory> memory, Keymap keymap)
      : editor_(memory, keymap),
        recent_(memory),
        draft_(memory),
        delivery_(memory) {}

  Editor& Line::editorMut() noexcept {
    return editor_;
  }

  const Editor& Line::editor() const noexcept {
    return editor_;
  }

  std::string_view Line::delivery() const noexcept {
    return delivery_.view();
  }

  std::uint64_t Line::revision() const noexcept {
    return revision_ + editor_.text().revision();
  }

  bool Line::queued() const noexcept {
    return armed_;
  }

  void Line::disarm() noexcept {
    if (std::exchange(armed_, false)) {
      ++revision_;
    }
  }

  bool Line::answering() const noexcept {
    return answering_;
  }

  std::uint32_t Line::secretKeys() const noexcept {
    return secret_keys_;
  }

  History Line::recent() const noexcept {
    return recent_.view();
  }

  void Line::setKeymap(Keymap keymap) {
    if (editor_.keymap() != keymap) {
      editor_.setKeymap(keymap);
      ++revision_;
    }
  }

  tbc::val_a<std::string_view> Line::suggestion(tbc::val_a<History> history) const noexcept {
    const auto& text = editor_.text();

    if (textIsSmallAndInVimMode(text)) {
      return {};
    }

    const auto view = text.view();

    for (const auto& entry : std::views::reverse(recent_)) {
      if (isCommandExtendedBy(entry, view)) {
        auto rest = entry.view();

        rest.remove_prefix(view.size());
        return rest;
      }
    }

    for (const auto& command : history) {
      if (isCommandExtendedBy(command, view)) {
        auto rest = command.view();

        rest.remove_prefix(view.size());
        return rest;
      }
    }

    return {};
  }

  bool Line::claims(const KeyPress& key, History history) const noexcept {
    if (menu_) {
      return true;
    }

    return (takesSuggestion(key) || takesSuggestedWord(key)) && !suggestion(history).empty();
  }

  Outcome Line::pressKey(Surface surface, const KeyPress& key, const Continuation& incomplete, History history) {
    delivery_.clear();
    const auto rest = suggestion(history);
    // → and Ctrl-E at the end take the whole suggestion, Alt-F its next word, as fish does.
    if (!rest.empty()) {
      const bool all = takesSuggestion(key);
      const bool word = takesSuggestedWord(key);

      if (all || word) {
        const auto taken = word ? nextWord(rest) : rest;
        // Copied: the suggestion views the history the insert may change.
        const ds::String<Memory> copy{draft_.memory(), taken};

        editor_.textMut().insert(copy);
        return Outcome::edited;
      }
    }

    bool refining = false;

    refining_ = false;

    if (menu_) {
      if (const auto outcome = menuKey(key, refining)) {
        return *outcome;
      }
    }

    if (surface == Surface::running && key.key == Key::enter && key.modifiers.alt) {
      answering_ = !answering_;
      ++revision_;
      return Outcome::edited;
    }

    const auto outcome = handle(editor_.press(key), surface, incomplete, history);

    return refining && menu_ ? refine(outcome) : outcome;
  }

  Outcome Line::performAction(Surface surface, Action action, const Continuation& incomplete, History history) {
    delivery_.clear();
    closeMenu();
    if (action == Action::accept_suggestion) {
      if (const auto rest = suggestion(history); !rest.empty()) {
        const ds::String<Memory> copy{draft_.memory(), rest};

        editor_.textMut().insert(copy);
      }

      return Outcome::edited;
    }

    return handle(editor_.perform(action), surface, incomplete, history);
  }

  void Line::insertText(std::string_view text) {
    closeMenu();
    editor_.insertText(text);
  }

  void Line::replaceText(std::size_t begin, std::size_t end, std::string_view text) {
    closeMenu();
    editor_.textMut().replace(begin, end, text);
  }

  void Line::write(std::string_view command) {
    closeMenu();
    history_index_.reset();
    auto& text = editor_.textMut();

    text.assign(command);
    editor_.placeAtEnd();
  }

  const ds::Option<Menu>& Line::menu() const noexcept {
    return menu_;
  }

  void Line::offer(tbc::val_a<Choices> choices, WordRange word, tbc::val_a<ds::Vec<std::uint64_t, Memory>> requests, shell::Dialect dialect, std::string_view label) {
    const bool whole = choices.size() <= Menu::capacity;
    if (!whole) {
      choices.truncate(Menu::capacity);
    }

    Menu menu{draft_.memory()};

    menu.all = choices.clone();
    menu.choices = std::move(choices);
    menu.begin = word.begin;
    menu.end = word.end;
    menu.requests = std::move(requests);
    menu.dialect = dialect;
    menu.label.assign(label);
    menu.floor = word.end;
    menu.whole = whole;
    menu.refined = std::exchange(refining_, false);
    menu_ = std::move(menu);
    settle();
    ++revision_;
  }

  bool Line::receive(std::uint64_t request, tbc::val_a<Choices> paths, bool truncated) {
    if (!menu_ || menu_.getMut().requests.retain([request](std::uint64_t waiting) {
          return waiting != request;
        }) == 0) {
      return false;
    }

    menu_.getMut().whole = menu_->whole && !truncated && menu_->all.size() + paths.size() <= Menu::capacity;
    // Typing narrowed the word while the choices were on their way, which come cut short: the
    // ones it narrows to may be past the cut, so the word as it is now is asked for again.
    if (!menu_->whole && menu_->requests.empty() && editor_.text().cursor() != menu_->floor) {
      menu_.reset();
      refining_ = true;
      asks_again_ = true;
      ++revision_;
      return true;
    }

    // Answers to an older word join, narrowed to the word as it is now, as the shell reads it.
    // The word is owned, as the menu grows while it is compared.
    auto typed = menuContext(draft_.memory(), editor_, *menu_);
    const auto word = typed ? std::move(typed.getMut().partial) : ds::String<Memory>{draft_.memory(), typedWord()};

    for (auto& path : paths.viewMut()) {
      if (menu_->all.size() < Menu::capacity && std::ranges::none_of(menu_->all, [&](const Choice& choice) {
            return choice.text == path.text;
          })) {
        if (path.text.view().starts_with(word.view())) {
          menu_.getMut().choices.push(path.clone());
        }

        menu_.getMut().all.push(std::move(path));
      }
    }

    settle();
    ++revision_;
    return true;
  }

  bool Line::takeAskAgain() noexcept {
    return std::exchange(asks_again_, false);
  }

  bool Line::pending(std::uint64_t request) const noexcept {
    return menu_ && std::ranges::find(menu_->requests, request) != menu_->requests.end();
  }

  Outcome Line::promptReturned(bool succeeded) {
    delivery_.clear();
    secret_keys_ = 0;
    answering_ = false;
    if (!armed_) {
      return Outcome::edited;
    }

    armed_ = false;
    ++revision_;
    if (!succeeded || editor_.text().empty()) {
      return Outcome::edited;
    }

    delivery_.assign(editor_.text().view());
    return Outcome::run;
  }

  void Line::committed(std::string_view command) {
    remember(command);
    editor_.clear();
    history_index_.reset();
    ++revision_;
  }

  void Line::countSecretKey() noexcept {
    ++secret_keys_;
    ++revision_;
  }

  void Line::eraseSecretKey() noexcept {
    if (secret_keys_ != 0) {
      --secret_keys_;
      ++revision_;
    }
  }

  void Line::clearSecret() noexcept {
    if (secret_keys_ != 0) {
      secret_keys_ = 0;
      ++revision_;
    }
  }

  void Line::remember(std::string_view command) {
    if (command.empty() || (!recent_.empty() && recent_.back() == command)) {
      return;
    }

    if (recent_.size() == recent_capacity) {
      static_cast<void>(recent_.remove(0));
    }

    recent_.emplace(recent_.memory(), command);
  }

  bool Line::textIsSmallAndInVimMode(const Text& text) const {
    return text.size() < 2 || text.cursor() != text.size() || menu_ || (editor_.keymap() == Keymap::vim && editor_.mode() != Mode::insert);
  }

  bool Line::isCommandExtendedBy(std::string_view command, std::string_view text) {
    return command.size() > text.size() && command.starts_with(text);
  }

  Outcome Line::handle(Request request, Surface surface, const Continuation& incomplete, History history) {
    switch (request) {
    case Request::none:
      return Outcome::edited;
    case Request::submit:
      // An answer is the running program's to read, not the shell's to continue.
      return submit(surface, (surface != Surface::running || !answering_) && incomplete.incomplete(editor_.text().view()));
    case Request::history_previous:
      return travel(-1, history);
    case Request::history_next:
      return travel(1, history);
    case Request::cancel:
      if (surface == Surface::running && editor_.text().empty()) {
        return Outcome::terminal;
      }

      editor_.cancel();
      armed_ = false;
      history_index_.reset();
      ++revision_;
      return Outcome::edited;
    case Request::end_of_file:
      if (surface == Surface::running) {
        return Outcome::terminal;
      }

      delivery_.assign("\x04");
      return Outcome::bytes;
    case Request::clear_screen:
      delivery_.assign("\x0c");
      return surface == Surface::editor ? Outcome::bytes : Outcome::ignored;
    case Request::complete:
      return Outcome::complete;
    case Request::history_search:
      return surface == Surface::editor ? Outcome::search_history : Outcome::edited;
    case Request::last_argument:
      return lastArgument(history);
    case Request::unhandled:
      return Outcome::ignored;
    }

    return Outcome::ignored;
  }

  void Line::closeMenu() noexcept {
    if (menu_) {
      menu_.reset();
      ++revision_;
    }
  }

  void Line::settle() {
    if (!menu_->requests.empty()) {
      return;
    }

    if (menu_->choices.size() == 1 && !menu_->refined) {
      accept();
    } else if (menu_->choices.empty()) {
      menu_.reset();
    } else if (!menu_->refined && menu_->whole) {
      // Of a cut list, what the choices shown share may not be what every choice does.
      writeCommonStart();
    }
  }

  void Line::accept() {
    const auto& choice = menu_->choices[menu_->selected];
    // Copied: the menu goes once the choice is written.
    const ds::String<Memory> text{draft_.memory(), choice.text.view()};

    writeChoice(text.view(), !choice.directory && !choice.joined);
    menu_.reset();
  }

  void Line::writeChoice(std::string_view text, bool ends) {
    const auto typed = menuContext(draft_.memory(), editor_, *menu_);
    const auto& menu = *menu_;
    const auto begin = menu.begin;
    auto end = std::min(menu.end, editor_.text().size());
    auto& memory = draft_.memory();
    ds::String<Memory> word{memory};
    const auto cursor = editor_.text().cursor();

    // A choice that goes on from what was typed keeps how it was typed: only what it adds is
    // escaped, inside the quote the word opened if it did, which closes once the word ends.
    if (typed && typed->replace_end == cursor && text.starts_with(typed->partial.view())) {
      const auto raw = editor_.text().view().substr(begin, cursor - begin);
      const auto added = text.substr(typed->partial.size());
      const char quote = openQuote(raw);

      word.assign(raw);
      if (quote == 0) {
        word.append(quoteWord(memory, added, menu.dialect));
      } else if (appendQuoted(word, added, quote, menu.dialect)) {
        if (ends) {
          word.push(quote);
        }
      } else {
        word = quoteWord(memory, text, menu.dialect);
      }

      end = cursor;
    } else {
      word = quoteWord(memory, text, menu.dialect);
    }

    if (ends) {
      word.push(' ');
    }

    editor_.textMut().replace(begin, end, word);
    ++revision_;
  }

  void Line::writeCommonStart() {
    const auto& choices = menu_->choices;
    auto common = choices[0].text.view();

    for (const auto& choice : choices) {
      const auto text = choice.text.view();
      const auto [ends, _] = std::ranges::mismatch(common, text);

      common = common.substr(0, static_cast<std::size_t>(ends - common.begin()));
    }

    // Whole characters only: a common start may end inside one.
    common = wholeCharacters(common);
    const auto typed = menuContext(draft_.memory(), editor_, *menu_);
    if (!typed || typed->replace_end != editor_.text().cursor() || common.size() <= typed->partial.size() || !common.starts_with(typed->partial.view())) {
      return;
    }

    const ds::String<Memory> text{draft_.memory(), common};

    writeChoice(text.view(), false);
    menu_.getMut().end = editor_.text().cursor();
  }

  ds::Option<Outcome> Line::menuKey(const KeyPress& key, bool& refining) {
    auto& menu = menu_.getMut();
    const auto count = menu.choices.size();
    const auto step = menuStep(key);
    if (count != 0 && step != MenuStep::none) {
      menu.selected = (menu.selected + (step == MenuStep::forward ? 1 : count - 1)) % count;
      menu.cycled = true;
      ++revision_;
      return Outcome::edited;
    }

    // Space after moving through the choices takes the selected one, and is typed after it when
    // the choice does not end in one.
    if (count != 0 && menu.cycled && key.key == Key::character && key.character == U' ' && !key.modifiers.control && !key.modifiers.alt) {
      const bool spaced = !menu.choices[menu.selected].directory && !menu.choices[menu.selected].joined;

      accept();
      if (!spaced) {
        editor_.textMut().insert(" ");
      }

      return Outcome::edited;
    }

    if (key.key == Key::enter && count != 0) {
      accept();
      return Outcome::edited;
    }

    if (key.key == Key::escape) {
      closeMenu();
      return Outcome::edited;
    }

    // Typing in the word, or erasing it, refines the choices once the editor has the key.
    const bool inserting = editor_.keymap() == Keymap::emacs || editor_.mode() == Mode::insert;
    const bool plain = !key.modifiers.control && !key.modifiers.alt;
    const bool typing = key.key == Key::character && plain && key.character > U' ' && key.character != 0x7f;
    if (inserting && (typing || (key.key == Key::backspace && plain))) {
      refining = true;
      return ds::none;
    }

    closeMenu();
    return ds::none;
  }

  std::string_view Line::typedWord() const noexcept {
    const auto text = editor_.text().view();
    if (!menu_ || menu_->begin > menu_->end || menu_->end > text.size()) {
      return {};
    }

    const auto chars = std::span{text}.subspan(menu_->begin, menu_->end - menu_->begin);

    return {chars.data(), chars.size()};
  }

  Outcome Line::refine(Outcome outcome) {
    auto typed = menuContext(draft_.memory(), editor_, *menu_);
    auto& menu = menu_.getMut();
    const auto cursor = editor_.text().cursor();
    if (cursor < menu.begin || !typed) {
      closeMenu();
      return outcome;
    }

    menu.end = cursor;
    if (cursor < menu.floor || (!menu.whole && cursor != menu.floor)) {
      menu_.reset();
      refining_ = true;
      ++revision_;
      return Outcome::complete;
    }

    // Owned, as the choices are rebuilt while it is compared.
    const auto word = std::move(typed.getMut().partial);

    // As typed first; ignoring case when nothing matches so.
    menu.choices.clear();
    for (const auto& choice : menu.all) {
      if (choice.text.view().starts_with(word.view())) {
        menu.choices.push(choice.clone());
      }
    }

    if (menu.choices.empty()) {
      for (const auto& choice : menu.all) {
        if (startsFolded(choice.text.view(), word.view())) {
          menu.choices.push(choice.clone());
        }
      }
    }

    menu.selected = 0;
    menu.refined = true;
    if (menu.choices.empty() && menu.requests.empty()) {
      closeMenu();
    }

    ++revision_;
    return outcome;
  }

  Outcome Line::submit(Surface surface, bool incomplete) {
    if (incomplete) {
      editor_.newline();
      return Outcome::edited;
    }

    if (surface == Surface::running) {
      if (answering_) {
        delivery_.assign(editor_.text().view());
        return Outcome::answer;
      }

      armed_ = !editor_.text().empty();
      ++revision_;
      return Outcome::edited;
    }

    // A blank line runs nothing: sent, the shell would only print its prompt again, which no
    // command's separator covers.
    if (editor_.text().view().find_first_not_of(" \t\n") == std::string_view::npos) {
      if (!editor_.text().empty()) {
        editor_.clear();
        ++revision_;
      }

      return Outcome::edited;
    }

    delivery_.assign(editor_.text().view());
    return Outcome::run;
  }

  Outcome Line::travel(int direction, History history) {
    // An edit of what Up brought back makes it the line being written: moving through it, as
    // between the lines of a command of several, does not.
    if (history_index_ && editor_.text().revision() != recalled_) {
      history_index_.reset();
    }

    if (!history_index_) {
      if (direction > 0) {
        return Outcome::edited;
      }

      if (!back(1, history)) {
        return Outcome::edited;
      }

      draft_.assign(editor_.text().view());
      history_index_ = 0;
    }

    const auto steps = direction < 0 ? *history_index_ + 1 : *history_index_ - 1;

    if (steps == 0) {
      history_index_.reset();
      editor_.textMut().assign(draft_);
    } else if (const auto entry = back(steps, history)) {
      // Copied: the entry views the history the assignment may outlive.
      const ds::String<Memory> command{draft_.memory(), *entry};

      history_index_ = steps;
      editor_.textMut().assign(command);
    } else {
      return Outcome::edited;
    }

    editor_.placeAtEnd();
    recalled_ = editor_.text().revision();
    ++revision_;
    return Outcome::edited;
  }

  Outcome Line::lastArgument(History history) {
    auto& text = editor_.textMut();
    const bool again = argument_steps_ != 0 && text.revision() == argument_revision_ && text.cursor() == argument_end_;
    const auto steps = again ? argument_steps_ + 1 : 1;
    const auto command = back(steps, history);
    if (!command) {
      return Outcome::edited;
    }

    // Its last word, as the shell splits words on blanks.
    const auto words = command->substr(0, command->find_last_not_of(" \t\n") + 1);
    const auto argument = words.substr(words.find_last_of(" \t\n") + 1);
    // Copied: the history the argument views may change as the text does.
    const ds::String<Memory> copy{draft_.memory(), argument};
    const auto start = again ? argument_start_ : text.cursor();

    text.replace(start, again ? argument_end_ : start, copy.view());
    argument_steps_ = steps;
    argument_start_ = start;
    argument_end_ = start + copy.size();
    argument_revision_ = text.revision();
    ++revision_;
    return Outcome::edited;
  }

  ds::Option<std::string_view> Line::back(std::size_t steps, History history) const noexcept {
    const auto own = recent_.view();
    std::size_t seen = 0;

    for (std::size_t index = own.size(); index-- > 0;) {
      const auto command = own[index].view();
      const auto newer = own.subspan(index + 1);
      if (std::ranges::any_of(newer, [command](const ds::String<Memory>& sent) {
            return sent.view() == command;
          })) {
        continue;
      }

      if (++seen == steps) {
        return command;
      }
    }

    for (const auto& entry : history) {
      const auto command = entry.view();
      if (std::ranges::any_of(own, [command](const ds::String<Memory>& sent) {
            return sent.view() == command;
          })) {
        continue;
      }

      if (++seen == steps) {
        return command;
      }
    }

    return ds::none;
  }

}
