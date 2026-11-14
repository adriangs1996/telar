module telar.gui.prompt.line;

import std;

namespace telar::gui::prompt {

  Line::Line(Keymap keymap)
      : editor_(keymap) {}

  Editor& Line::editor() noexcept {
    return editor_;
  }

  const Editor& Line::editor() const noexcept {
    return editor_;
  }

  std::string_view Line::delivery() const noexcept {
    return delivery_;
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

  const std::vector<std::string>& Line::recent() const noexcept {
    return recent_;
  }

  void Line::setKeymap(Keymap keymap) {
    if (editor_.keymap() != keymap) {
      editor_.setKeymap(keymap);
      ++revision_;
    }
  }

  std::string_view Line::suggestion(std::span<const std::string> history) const noexcept {
    const auto& text = editor_.text();

    if (textIsSmallAndInVimMode(text)) {
      return {};
    }

    const auto view = text.view();

    for (const auto& entry : std::views::reverse(recent_)) {
      if (isCommandExtendedBy(entry, view)) {
        return std::string_view{entry}.substr(view.size());
      }
    }

    for (const auto& command : history) {
      if (isCommandExtendedBy(command, view)) {
        return std::string_view{command}.substr(view.size());
      }
    }

    return {};
  }

  Outcome Line::pressKey(Surface surface, const KeyPress& key, const Continuation& incomplete, std::span<const std::string> history) {
    delivery_.clear();
    const auto rest = suggestion(history);
    // → and Ctrl-E at the end take the whole suggestion, Alt-F its next word, as fish does.
    if (!rest.empty()) {
      const bool all = (key.key == Key::right && !key.modifiers.alt && !key.modifiers.shift) || key.key == Key::end || (key.key == Key::character && key.modifiers.control && (key.character == 'e' || key.character == 'f'));
      const bool word = (key.key == Key::character && key.modifiers.alt && key.character == 'f') || (key.key == Key::right && key.modifiers.alt);

      if (all || word) {
        auto taken = rest;

        if (word) {
          const auto start = taken.find_first_not_of(' ');
          const auto end = taken.find_first_of(" /", start == std::string_view::npos ? 0 : start);

          taken = taken.substr(0, end == std::string_view::npos ? taken.size() : end + (taken[end] == '/' ? 1 : 0));
        }

        const std::string copy{taken};

        editor_.text().insert(copy);
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

    const auto outcome = handle(editor_.press(key), surface, incomplete);

    return refining && menu_ ? refine(outcome) : outcome;
  }

  Outcome Line::performAction(Surface surface, Action action, const Continuation& incomplete, std::span<const std::string> history) {
    delivery_.clear();
    closeMenu();
    if (action == Action::accept_suggestion) {
      if (const auto rest = suggestion(history); !rest.empty()) {
        const std::string copy{rest};

        editor_.text().insert(copy);
      }

      return Outcome::edited;
    }

    return handle(editor_.perform(action), surface, incomplete);
  }

  void Line::insertText(std::string_view text) {
    closeMenu();
    editor_.insertText(text);
  }

  void Line::replaceText(std::size_t begin, std::size_t end, std::string_view text) {
    closeMenu();
    editor_.text().replace(begin, end, text);
  }

  const std::optional<Menu>& Line::menu() const noexcept {
    return menu_;
  }

  void Line::offer(std::vector<Choice> choices, std::size_t begin, std::size_t end, std::vector<std::uint64_t> requests, shell::Dialect dialect, std::string label) {
    const bool whole = choices.size() <= Menu::capacity;
    if (!whole) {
      choices.resize(Menu::capacity);
    }

    auto all = choices;

    menu_ = Menu{.choices = std::move(choices), .begin = begin, .end = end, .requests = std::move(requests), .dialect = dialect, .label = std::move(label), .all = std::move(all), .floor = end, .whole = whole, .refined = std::exchange(refining_, false)};
    settle();
    ++revision_;
  }

  bool Line::receive(std::uint64_t request, std::span<const Choice> paths, bool truncated) {
    if (!menu_ || std::erase(menu_->requests, request) == 0) {
      return false;
    }

    menu_->whole = menu_->whole && !truncated && menu_->all.size() + paths.size() <= Menu::capacity;
    // Answers to an older word join, narrowed to the word as it is now.
    const auto word = typedWord();

    for (const auto& path : paths) {
      if (menu_->all.size() < Menu::capacity && std::ranges::none_of(menu_->all, [&](const Choice& choice) {
            return choice.text == path.text;
          })) {
        menu_->all.push_back(path);
        if (path.text.starts_with(word)) {
          menu_->choices.push_back(path);
        }
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
    remember(delivery_);
    editor_.clear();
    return Outcome::run;
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
      recent_.erase(recent_.begin());
    }

    recent_.emplace_back(command);
  }

  bool Line::textIsSmallAndInVimMode(const Text& text) const {
    return text.size() < 2 || text.cursor() != text.size() || menu_ || (editor_.keymap() == Keymap::vim && editor_.mode() != Mode::insert);
  }

  bool Line::isCommandExtendedBy(std::string_view command, std::string_view text) {
    return command.size() > text.size() && command.starts_with(text);
  }

  Outcome Line::handle(Request request, Surface surface, const Continuation& incomplete) {
    switch (request) {
    case Request::none:
      history_index_.reset();
      return Outcome::edited;
    case Request::submit:
      return submit(surface, incomplete.incomplete(editor_.text().view()));
    case Request::history_previous:
      return travel(-1);
    case Request::history_next:
      return travel(1);
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
    const auto& menu = *menu_;
    const auto& choice = menu.choices[menu.selected];
    auto word = quoteWord(choice.text, menu.dialect);

    if (!choice.directory) {
      word.push_back(' ');
    }

    const auto begin = menu.begin;
    const auto end = std::min(menu.end, editor_.text().size());

    menu_.reset();
    editor_.text().replace(begin, end, word);
    ++revision_;
  }

  std::optional<Outcome> Line::menuKey(const KeyPress& key, bool& refining) {
    auto& menu = *menu_;
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
      return std::nullopt;
    }

    closeMenu();
    return std::nullopt;
  }

  std::string_view Line::typedWord() const noexcept {
    const auto text = editor_.text().view();
    if (!menu_ || menu_->begin > menu_->end || menu_->end > text.size()) {
      return {};
    }

    return text.substr(menu_->begin, menu_->end - menu_->begin);
  }

  Outcome Line::refine(Outcome outcome) {
    auto& menu = *menu_;
    const auto& text = editor_.text();
    const auto cursor = text.cursor();
    if (cursor < menu.begin || text.view().substr(menu.begin, cursor - menu.begin).find_first_of(" \t\n") != std::string_view::npos) {
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

    const auto word = typedWord();

    menu.choices.clear();
    for (const auto& choice : menu.all) {
      if (choice.text.starts_with(word)) {
        menu.choices.push_back(choice);
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
        editor_.clear();
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
    remember(delivery_);
    editor_.clear();
    history_index_.reset();
    return Outcome::run;
  }

  Outcome Line::travel(int direction) {
    if (recent_.empty()) {
      return Outcome::edited;
    }

    if (!history_index_) {
      if (direction > 0) {
        return Outcome::edited;
      }

      draft_.assign(editor_.text().view());
      history_index_ = recent_.size();
    }

    const auto next = static_cast<std::ptrdiff_t>(*history_index_) + direction;
    if (next < 0) {
      return Outcome::edited;
    }

    if (static_cast<std::size_t>(next) >= recent_.size()) {
      history_index_.reset();
      editor_.text().assign(draft_);
    } else {
      history_index_ = static_cast<std::size_t>(next);
      editor_.text().assign(recent_[*history_index_]);
    }

    editor_.text().moveTo(editor_.text().size());
    ++revision_;
    return Outcome::edited;
  }

}
