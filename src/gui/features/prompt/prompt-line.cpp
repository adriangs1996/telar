module telar.gui.features.prompt;

import std;

import telar.shell.syntax;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  namespace {

    bool takesSuggestion(const KeyPress& key) noexcept {
      return (key.key == Key::right && !key.modifiers.alt && !key.modifiers.shift) || key.key == Key::end || (key.key == Key::character && key.modifiers.control && (key.character == 'e' || key.character == 'f'));
    }

    bool takesSuggestedWord(const KeyPress& key) noexcept {
      return (key.key == Key::character && key.modifiers.alt && key.character == 'f') || (key.key == Key::right && key.modifiers.alt);
    }

    // The quote a word opens and leaves open: its first byte, when nothing closes it after.
    char openQuote(std::string_view word) noexcept {
      if (word.empty() || (word.front() != '"' && word.front() != '\'')) {
        return 0;
      }

      const char quote = word.front();

      for (std::size_t index = 1; index < word.size(); ++index) {
        if (quote == '"' && word[index] == '\\') {
          ++index;
        } else if (word[index] == quote) {
          return 0;
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
    // Answers to an older word join, narrowed to the word as it is now, as the shell reads it.
    const auto typed = menuWord();
    const auto word = typed ? typed->partial.view() : typedWord();

    for (auto& path : paths.viewMut()) {
      if (menu_->all.size() < Menu::capacity && std::ranges::none_of(menu_->all, [&](const Choice& choice) {
            return choice.text == path.text;
          })) {
        if (path.text.view().starts_with(word)) {
          menu_.getMut().choices.push(path.clone());
        }

        menu_.getMut().all.push(std::move(path));
      }
    }

    settle();
    ++revision_;
    return true;
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
      history_index_.reset();
      return Outcome::edited;
    case Request::submit:
      return submit(surface, incomplete.incomplete(editor_.text().view()));
    case Request::history_previous:
      return travel(-1, history);
    case Request::history_next:
      return travel(1, history);
    case Request::cancel:
      if (surface == Surface::running && editor_.text().empty()) {
        return Outcome::terminal;
      }

      editor_.clear();
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
    }
  }

  void Line::accept() {
    const auto typed = menuWord();
    const auto& menu = *menu_;
    const auto& choice = menu.choices[menu.selected];
    const auto begin = menu.begin;
    auto end = std::min(menu.end, editor_.text().size());
    auto& memory = draft_.memory();
    ds::String<Memory> word{memory};
    const auto cursor = editor_.text().cursor();

    // A choice that goes on from what was typed keeps how it was typed: only what it adds is
    // escaped, inside the quote the word opened if it did, which closes once the word ends.
    if (typed && typed->replace_end == cursor && choice.text.view().starts_with(typed->partial.view())) {
      const auto raw = editor_.text().view().substr(begin, cursor - begin);
      const auto added = choice.text.view().substr(typed->partial.size());
      const char quote = openQuote(raw);

      word.assign(raw);
      if (quote == 0) {
        word.append(quoteWord(memory, added, menu.dialect));
      } else if (appendQuoted(word, added, quote, menu.dialect)) {
        if (!choice.directory && !choice.joined) {
          word.push(quote);
        }
      } else {
        word = quoteWord(memory, choice.text, menu.dialect);
      }

      end = cursor;
    } else {
      word = quoteWord(memory, choice.text, menu.dialect);
    }

    if (!choice.directory && !choice.joined) {
      word.push(' ');
    }

    menu_.reset();
    editor_.textMut().replace(begin, end, word);
    ++revision_;
  }

  ds::Option<Outcome> Line::menuKey(const KeyPress& key, bool& refining) {
    auto& menu = menu_.getMut();
    const auto count = menu.choices.size();
    const bool forward = (key.key == Key::tab && !key.modifiers.shift) || key.key == Key::down || (key.key == Key::character && key.modifiers.control && key.character == 'n');
    const bool backward = key.key == Key::backtab || (key.key == Key::tab && key.modifiers.shift) || key.key == Key::up || (key.key == Key::character && key.modifiers.control && key.character == 'p');
    if (count != 0 && (forward || backward)) {
      menu.selected = (menu.selected + (forward ? 1 : count - 1)) % count;
      ++revision_;
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
    const auto typed = menuWord();
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

    const auto word = typed->partial.view();

    menu.choices.clear();
    for (const auto& choice : menu.all) {
      if (choice.text.view().starts_with(word)) {
        menu.choices.push(choice.clone());
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

  ds::Option<CompletionContext> Line::menuWord() {
    const auto& text = editor_.text();
    auto context = completionContext(draft_.memory(), text.view(), text.cursor(), shell::Syntax{.dialect = menu_->dialect});
    if (!context || context->replace_begin != menu_->begin) {
      return ds::none;
    }

    return context;
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

    editor_.textMut().moveTo(editor_.textMut().size());
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
