module telar.gui.features.prompt;

import std;
import telar.base.ds;
import telar.tbc;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  tbc::val_a<Editor::Recorded> Editor::Recorded::clone() const {
    return {.key = key, .text = text.clone()};
  }

  Editor::Editor(tbc::mut_a<Memory> memory, Keymap keymap)
      : text_(memory),
        keymap_(keymap),
        kill_ring_(memory),
        pasted_(memory),
        unnamed_{.text = ds::String<Memory>{memory}},
        registers_(memory),
        recorded_(memory),
        last_change_(memory) {
    constexpr std::size_t named_registers = 26;

    registers_.reserve(named_registers);
    for (std::size_t index = 0; index < named_registers; ++index) {
      registers_.push(Register{.text = ds::String<Memory>{memory}});
    }
  }

  Memory& Editor::memory() const noexcept {
    return kill_ring_.memory();
  }

  Text& Editor::textMut() noexcept {
    return text_;
  }

  const Text& Editor::text() const noexcept {
    return text_;
  }

  Keymap Editor::keymap() const noexcept {
    return keymap_;
  }

  void Editor::setKeymap(Keymap keymap) noexcept {
    keymap_ = keymap;
    mode_ = Mode::insert;
    reset();
  }

  Mode Editor::mode() const noexcept {
    return mode_;
  }

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::visualRange() const noexcept {
    if (mode_ != Mode::visual && mode_ != Mode::visual_line) {
      return ds::none;
    }

    if (mode_ == Mode::visual_line) {
      return std::pair{text_.lineStart(text_.selectionStart()), text_.lineEnd(text_.selectionEnd())};
    }

    return std::pair{text_.selectionStart(), text_.next(text_.selectionEnd())};
  }

  bool Editor::pending() const noexcept {
    return count_ != 0 || operator_ != 0 || pending_ != Pending::none || register_pending_;
  }

  void Editor::setClipboard(tbc::val_a<Clipboard> clipboard) {
    clipboard_ = std::move(clipboard);
  }

  void Editor::clear() noexcept {
    text_.clear();
    mode_ = Mode::insert;
    reset();
  }

  void Editor::newline() {
    text_.insert("\n");
  }

  void Editor::insertText(std::string_view text) {
    if (keymap_ == Keymap::vim && mode_ != Mode::insert) {
      return;
    }

    text_.insert(text, true);
  }

  Request Editor::perform(Action action) {
    // Run as a key is: the column Up and Down keep lasts only as long as they follow each other.
    vertical_ = false;
    killing_ = false;
    const auto request = performAction(action);

    if (!vertical_) {
      goal_column_.reset();
    }

    killed_ = killing_;

    return request;
  }

  Request Editor::performAction(Action action) {
    const auto cursor = text_.cursor();

    switch (action) {
    case Action::submit:
      return Request::submit;
    case Action::newline:
      newline();
      return Request::none;
    case Action::cancel:
      return Request::cancel;
    case Action::complete:
      return Request::complete;
    case Action::accept_suggestion:
      return Request::none;
    case Action::history_previous:
      return Request::history_previous;
    case Action::history_next:
      return Request::history_next;
    case Action::history_search:
      return Request::history_search;
    case Action::line_start:
      move(text_.lineStart(cursor));
      return Request::none;
    case Action::line_end:
      move(text_.lineEnd(cursor));
      return Request::none;
    case Action::char_left:
      move(text_.previous(cursor));
      return Request::none;
    case Action::char_right:
      move(text_.next(cursor));
      return Request::none;
    case Action::word_left:
      move(wordStart(cursor, false));
      return Request::none;
    case Action::word_right:
      move(wordEnd(cursor));
      return Request::none;
    case Action::delete_char:
      text_.replace(cursor, text_.next(cursor), {}, true);
      return Request::none;
    case Action::backspace:
      text_.replace(text_.previous(cursor), cursor, {}, true);
      return Request::none;
    case Action::kill_line:
      kill(cursor, text_.lineEnd(cursor));
      return Request::none;
    case Action::kill_to_start:
      killBackward(text_.lineStart(cursor));
      return Request::none;
    case Action::kill_word:
      kill(cursor, wordEnd(cursor));
      return Request::none;
    case Action::kill_word_back:
      killBackward(wordStart(cursor, false));
      return Request::none;
    case Action::yank:
      text_.insert(kill_ring_);
      return Request::none;
    case Action::undo:
      text_.undo();
      return Request::none;
    case Action::redo:
      text_.redo();
      return Request::none;
    case Action::transpose:
      transpose();
      return Request::none;
    case Action::clear_screen:
      return Request::clear_screen;
    case Action::normal_mode:
      if (keymap_ == Keymap::vim && mode_ == Mode::insert) {
        enterNormal();
      }

      return Request::none;
    case Action::insert_mode:
      if (keymap_ == Keymap::vim && mode_ != Mode::insert) {
        mode_ = Mode::insert;
        text_.hold();
        reset();
      }

      return Request::none;
    }

    return Request::unhandled;
  }

  Request Editor::press(const KeyPress& key) {
    if (keymap_ == Keymap::vim && replaying_ == 0 && recording_) {
      record(key);
    }

    vertical_ = false;
    killing_ = false;
    const auto request = dispatch(key);

    // The column Up and Down keep lasts only as long as they follow each other, as kills join
    // only while they do.
    if (!vertical_) {
      goal_column_.reset();
    }

    killed_ = killing_;

    if (repeat_requested_) {
      repeat();
    }

    return request;
  }

  Request Editor::dispatch(const KeyPress& key) {
    return keymap_ == Keymap::vim && mode_ != Mode::insert ? normal(key) : insert(key);
  }

  Request Editor::insert(const KeyPress& key) {
    const auto& mods = key.modifiers;
    const auto cursor = text_.cursor();

    if (key.key == Key::character && mods.control && !mods.alt) {
      return control(key.character);
    }

    if (key.key == Key::character && mods.alt && !mods.control) {
      return meta(key.character);
    }

    switch (key.key) {
    case Key::character:
      if (!key.text.empty()) {
        text_.insert(key.text, true);
      }

      return Request::none;
    case Key::enter:
      if (mods.alt || mods.shift) {
        newline();
        return Request::none;
      }

      return Request::submit;
    case Key::backspace:
      eraseBackward(mods.alt || mods.control);
      return Request::none;
    case Key::delete_forward:
      if (text_.selecting()) {
        text_.insert({});
      } else {
        text_.replace(cursor, text_.next(cursor), {}, true);
      }

      return Request::none;
    case Key::left:
      move(mods.alt || mods.control ? wordStart(cursor, false) : text_.previous(cursor), mods.shift);
      return Request::none;
    case Key::right:
      move(mods.alt || mods.control ? wordEnd(cursor) : text_.next(cursor), mods.shift);
      return Request::none;
    case Key::up:
      return vertical(-1, mods.shift);
    case Key::down:
      return vertical(1, mods.shift);
    case Key::home:
      move(text_.lineStart(cursor), mods.shift);
      return Request::none;
    case Key::end:
      move(text_.lineEnd(cursor), mods.shift);
      return Request::none;
    case Key::tab:
      return Request::complete;
    case Key::backtab:
      return Request::unhandled;
    case Key::escape:
      return escapeInsert();
    }

    return Request::unhandled;
  }

  void Editor::eraseBackward(bool word) {
    const auto cursor = text_.cursor();

    if (text_.selecting()) {
      text_.insert({});
    } else if (word) {
      killBackward(wordStart(cursor, false));
    } else {
      text_.replace(text_.previous(cursor), cursor, {}, true);
    }
  }

  Request Editor::escapeInsert() {
    if (keymap_ == Keymap::vim) {
      enterNormal();
      return Request::none;
    }

    if (text_.selecting()) {
      text_.moveTo(text_.cursor());
      return Request::none;
    }

    return Request::unhandled;
  }

  Request Editor::control(char32_t character) {
    const auto cursor = text_.cursor();

    switch (character) {
    case 'a':
      move(text_.lineStart(cursor));
      return Request::none;
    case 'e':
      move(text_.lineEnd(cursor));
      return Request::none;
    case 'b':
      move(text_.previous(cursor));
      return Request::none;
    case 'f':
      move(text_.next(cursor));
      return Request::none;
    case 'p':
      return vertical(-1, false);
    case 'n':
      return vertical(1, false);
    case 'h':
      text_.replace(text_.previous(cursor), cursor, {}, true);
      return Request::none;
    case 'd':
      if (text_.empty()) {
        return Request::end_of_file;
      }

      text_.replace(cursor, text_.next(cursor), {}, true);
      return Request::none;
    case 'w':
      killBackward(bigWordStart(cursor));
      return Request::none;
    case 'u':
      killBackward(text_.lineStart(cursor));
      return Request::none;
    case 'k':
      kill(cursor, text_.lineEnd(cursor) == cursor && cursor < text_.size() ? cursor + 1 : text_.lineEnd(cursor));
      return Request::none;
    case 'y':
      text_.insert(kill_ring_);
      return Request::none;
    case 't':
      transpose();
      return Request::none;
    case '_':
    case '/':
      text_.undo();
      return Request::none;
    case 'r':
      return Request::history_search;
    case 'l':
      return Request::clear_screen;
    case 'c':
      return Request::cancel;
    case 'j':
    case 'm':
      return Request::submit;
    case 'g':
      text_.moveTo(text_.cursor());
      return Request::none;
    default:
      return Request::unhandled;
    }
  }

  Request Editor::meta(char32_t character) {
    const auto cursor = text_.cursor();

    switch (character) {
    case 'b':
      move(wordStart(cursor, false));
      return Request::none;
    case 'f':
      move(wordEnd(cursor));
      return Request::none;
    case 'd':
      kill(cursor, wordEnd(cursor));
      return Request::none;
    default:
      return Request::unhandled;
    }
  }

  void Editor::move(std::size_t offset, bool extend) noexcept {
    text_.moveTo(offset, extend);
  }

  Request Editor::vertical(int direction, bool extend) {
    const auto cursor = text_.cursor();
    const auto start = text_.lineStart(cursor);
    if (direction < 0 && start == 0) {
      return Request::history_previous;
    }

    if (direction > 0 && text_.lineEnd(cursor) == text_.size()) {
      return Request::history_next;
    }

    const auto column = goal_column_ ? *goal_column_ : text_.column(cursor);
    const auto target_start = direction < 0 ? text_.lineStart(start - 1) : text_.lineEnd(cursor) + 1;

    move(text_.atColumn({.line_start = target_start, .column = column}), extend);
    goal_column_ = column;
    vertical_ = true;
    return Request::none;
  }

  void Editor::kill(std::size_t start, std::size_t end) {
    if (start == end) {
      return;
    }

    // Kills in a row join one entry, as readline's do: one backward of the cursor goes before
    // what the others took, one forward of it after.
    const auto killed = text_.view().substr(start, end - start);

    if (!killed_) {
      kill_ring_.assign(killed);
    } else if (end == text_.cursor() && start < end) {
      kill_ring_.insert(0, killed);
    } else {
      kill_ring_.append(killed);
    }

    killing_ = true;
    text_.replace(start, end, {});
  }

  void Editor::killBackward(std::size_t start) {
    kill(start, text_.cursor());
  }

  void Editor::transpose() {
    auto cursor = text_.cursor();
    if (cursor == 0 || text_.size() < 2) {
      return;
    }

    if (cursor == text_.size()) {
      cursor = text_.previous(cursor);
    }

    const auto before = text_.previous(cursor);
    const auto after = text_.next(cursor);
    const auto view = text_.view();
    ds::String<Memory> swapped{memory(), view.substr(cursor, after - cursor)};

    swapped.append(view.substr(before, cursor - before));
    text_.replace(before, after, swapped);
  }

  bool Editor::blank(std::size_t offset) const noexcept {
    return offset >= text_.size() || classify(text_.view()[offset]) == CharacterClass::blank;
  }

  CharacterClass Editor::kind(std::size_t offset, bool big) const noexcept {
    const auto value = offset >= text_.size() ? CharacterClass::blank : classify(text_.view()[offset]);

    return big && value != CharacterClass::blank ? CharacterClass::word : value;
  }

  std::size_t Editor::wordStart(std::size_t offset, bool big) const noexcept {
    auto position = offset;

    while (position > 0 && blank(text_.previous(position))) {
      position = text_.previous(position);
    }

    if (position == 0) {
      return 0;
    }

    const auto run = kind(text_.previous(position), big);

    while (position > 0 && kind(text_.previous(position), big) == run) {
      position = text_.previous(position);
    }

    return position;
  }

  std::size_t Editor::bigWordStart(std::size_t offset) const noexcept {
    return wordStart(offset, true);
  }

  std::size_t Editor::wordEnd(std::size_t offset) const noexcept {
    auto position = offset;

    while (position < text_.size() && kind(position, false) != CharacterClass::word) {
      position = text_.next(position);
    }

    while (position < text_.size() && kind(position, false) == CharacterClass::word) {
      position = text_.next(position);
    }

    return position;
  }

  std::size_t Editor::nextWord(std::size_t offset, bool big) const noexcept {
    auto position = offset;
    const auto run = kind(position, big);
    if (run != CharacterClass::blank) {
      while (position < text_.size() && kind(position, big) == run) {
        position = text_.next(position);
      }
    }

    while (position < text_.size() && blank(position)) {
      position = text_.next(position);
    }

    return position;
  }

  std::size_t Editor::runEnd(std::size_t offset, bool big) const noexcept {
    const auto run = kind(offset, big);
    auto position = offset;

    while (text_.next(position) < text_.size() && kind(text_.next(position), big) == run) {
      position = text_.next(position);
    }

    return position;
  }

  std::size_t Editor::wordEndBackward(std::size_t offset, bool big) const noexcept {
    auto position = offset;

    // Out of the word the cursor is on, then over the blanks before it.
    if (!blank(position)) {
      const auto run = kind(position, big);

      while (position > 0 && kind(text_.previous(position), big) == run) {
        position = text_.previous(position);
      }
    }

    if (position == 0) {
      return 0;
    }

    position = text_.previous(position);
    while (position > 0 && blank(position)) {
      position = text_.previous(position);
    }

    return position;
  }

  std::size_t Editor::endOfWord(std::size_t offset, bool big) const noexcept {
    auto position = text_.next(offset);

    while (position < text_.size() && blank(position)) {
      position = text_.next(position);
    }

    if (position >= text_.size()) {
      return text_.empty() ? 0 : text_.previous(text_.size());
    }

    const auto run = kind(position, big);

    while (text_.next(position) < text_.size() && kind(text_.next(position), big) == run) {
      position = text_.next(position);
    }

    return position;
  }

  void Editor::reset() noexcept {
    count_ = 0;
    operator_ = 0;
    operator_count_ = 0;
    pending_ = Pending::none;
    register_pending_ = false;
    register_ = '"';
    goal_column_.reset();
  }

  void Editor::enterNormal() {
    mode_ = Mode::normal;
    text_.release();
    const auto cursor = text_.cursor();
    if (cursor > text_.lineStart(cursor)) {
      text_.moveTo(text_.previous(cursor));
    } else {
      text_.moveTo(cursor);
    }

    reset();
    finishRecording();
  }

  void Editor::enterInsert(std::size_t offset) {
    mode_ = Mode::insert;
    text_.moveTo(offset);
    text_.seal();
    text_.hold();
  }

  void Editor::clampNormal() noexcept {
    const auto cursor = text_.cursor();
    const auto end = text_.lineEnd(cursor);
    if (cursor == end && end > text_.lineStart(cursor)) {
      text_.moveTo(text_.previous(end), mode_ == Mode::visual || mode_ == Mode::visual_line);
    }
  }

  std::size_t Editor::count() const noexcept {
    return std::max<std::size_t>(1, count_) * std::max<std::size_t>(1, operator_count_);
  }

  namespace {

    // The vim command a key other than a character stands for, if any.
    ds::Option<char32_t> vimCharacter(const KeyPress& key) noexcept {
      switch (key.key) {
      case Key::left:
      case Key::backspace:
        return U'h';
      case Key::right:
        return U'l';
      case Key::up:
        return U'k';
      case Key::down:
        return U'j';
      case Key::home:
        return U'0';
      case Key::end:
        return U'$';
      case Key::delete_forward:
        return U'x';
      case Key::character:
        return key.character;
      case Key::enter:
      case Key::tab:
      case Key::backtab:
      case Key::escape:
        break;
      }

      // A key that stands for no command, or one outside the enum.
      return ds::none;
    }

  }

  Request Editor::normal(const KeyPress& key) {
    if (key.key == Key::escape) {
      if (mode_ == Mode::visual || mode_ == Mode::visual_line) {
        mode_ = Mode::normal;
        text_.moveTo(text_.cursor());
      }

      reset();
      finishRecording();
      return Request::none;
    }

    if (key.key == Key::enter && !pending()) {
      return Request::submit;
    }

    if (key.key == Key::character && key.modifiers.control) {
      return normalControl(key.character);
    }

    if (key.key == Key::tab) {
      return Request::complete;
    }

    const auto character = vimCharacter(key);
    if (!character) {
      return Request::unhandled;
    }

    if (const auto request = pendingKey(*character, key)) {
      return *request;
    }

    return normalKey(*character, key);
  }

  ds::Option<Request> Editor::pendingKey(char32_t character, const KeyPress& key) {
    if (register_pending_) {
      register_ = static_cast<char>(character);
      register_pending_ = false;
      return Request::none;
    }

    switch (pending_) {
    case Pending::replace:
      // A key that types nothing (Backspace, an arrow, Delete) cancels the r.
      if (key.key != Key::character || key.text.empty()) {
        reset();
        return Request::none;
      }

      replaceCharacters(key.text);
      return Request::none;
    case Pending::find:
      last_find_ = Find{.kind = find_kind_, .target = character};
      return applyMotion(findMotion(last_find_, count()));
    case Pending::g:
      return afterG(character);
    case Pending::text_object:
      return applyTextObject(character);
    case Pending::none:
      return ds::none;
    }

    return ds::none;
  }

  Request Editor::afterG(char32_t character) {
    pending_ = Pending::none;
    if (character == 'g') {
      return applyMotion(Motion{.target = 0, .inclusive = false, .linewise = true});
    }

    if (character == 'e' || character == 'E') {
      auto target = text_.cursor();

      for (std::size_t index = 0; index < count(); ++index) {
        target = wordEndBackward(target, character == 'E');
      }

      return applyMotion(Motion{.target = target, .inclusive = true});
    }

    reset();
    return Request::none;
  }

  bool Editor::countDigit(char32_t character) noexcept {
    // A count's digits; past four, more digits only make vim slower.
    constexpr std::size_t decimal_base = 10;
    constexpr std::size_t maximum_count = 9999;
    auto& target = operator_ != 0 ? operator_count_ : count_;

    if ((character < '1' || character > '9') && (character != '0' || target == 0)) {
      return false;
    }

    target = std::min<std::size_t>((target * decimal_base) + (character - '0'), maximum_count);
    return true;
  }

  Request Editor::normalKey(char32_t character, const KeyPress& key) {
    if (countDigit(character)) {
      return Request::none;
    }

    // j and k past the first or last line reach the history, as Up and Down do.
    if ((character == 'j' || character == 'k') && operator_ == 0 && mode_ == Mode::normal) {
      const auto cursor = text_.cursor();
      if (character == 'k' && text_.lineStart(cursor) == 0) {
        reset();
        return Request::history_previous;
      }

      if (character == 'j' && text_.lineEnd(cursor) == text_.size()) {
        reset();
        return Request::history_next;
      }
    }

    if (const auto motion = motionFor(character)) {
      return applyMotion(*motion);
    }

    if ((character == 'i' || character == 'a') && (operator_ != 0 || mode_ == Mode::visual || mode_ == Mode::visual_line)) {
      pending_ = Pending::text_object;
      text_object_inner_ = character == 'i';
      return Request::none;
    }

    if (character == 'f' || character == 'F' || character == 't' || character == 'T') {
      pending_ = Pending::find;
      find_kind_ = static_cast<char>(character);
      return Request::none;
    }

    if (character == 'g') {
      pending_ = Pending::g;
      return Request::none;
    }

    return command(character, key);
  }

  Request Editor::normalControl(char32_t character) {
    switch (character) {
    case 'r':
      for (std::size_t step = 0; step < count(); ++step) {
        text_.redo();
      }

      reset();
      clampNormal();
      return Request::none;
    case 'c':
      return Request::cancel;
    case 'l':
      return Request::clear_screen;
    case 'd':
      return text_.empty() ? Request::end_of_file : Request::none;
    case 'p':
      return vertical(-1, false);
    case 'n':
      return vertical(1, false);
    default:
      return Request::unhandled;
    }
  }

  ds::Option<Editor::Motion> Editor::motionFor(char32_t character) const {
    const auto cursor = text_.cursor();
    const auto repeat = count();
    const auto apply = [&](auto step) {
      auto position = cursor;

      for (std::size_t index = 0; index < repeat; ++index) {
        position = step(position);
      }

      return position;
    };

    switch (character) {
    case 'h':
      return Motion{
          .target = apply([&](std::size_t offset) {
            return offset > text_.lineStart(cursor) ? text_.previous(offset) : offset;
          }),
      };
    case 'l':
    case ' ':
      return Motion{
          .target = apply([&](std::size_t offset) {
            // A visual selection stops on the line's last character, as vim's does.
            const auto line_end = text_.lineEnd(cursor);
            const auto last = (mode_ == Mode::visual || mode_ == Mode::visual_line) && line_end > text_.lineStart(cursor) ? text_.previous(line_end) : line_end;

            return offset < last ? text_.next(offset) : offset;
          }),
      };
    case 'w':
    case 'W':
      return wordMotion(character == 'W');
    case 'b':
    case 'B':
      return Motion{
          .target = apply([&](std::size_t offset) {
            return wordStart(offset, character == 'B');
          }),
      };
    case 'e':
    case 'E':
      return Motion{
          .target = apply([&](std::size_t offset) {
            return endOfWord(offset, character == 'E');
          }),
          .inclusive = true,
      };
    case '0':
      return Motion{.target = text_.lineStart(cursor)};
    case '^':
      return Motion{.target = firstNonBlank(text_.lineStart(cursor))};
    case '$':
      return lineEndMotion();
    case 'G':
      if (count_ == 0 && operator_count_ == 0) {
        return Motion{.target = text_.lineStart(text_.size()), .inclusive = false, .linewise = true};
      }

      return Motion{.target = lineAt(repeat - 1), .inclusive = false, .linewise = true};
    case 'j':
    case 'k':
      return lineMotion(character == 'j');
    case ';':
    case ',':
      if (last_find_.target == 0) {
        return Motion{.target = cursor, .valid = false};
      }

      return findMotion(character == ';' ? last_find_ : Find{.kind = reversed(last_find_.kind), .target = last_find_.target}, repeat, true);
    case '%':
      return matchingBracket(cursor);
    default:
      return ds::none;
    }
  }

  Editor::Motion Editor::wordMotion(bool big) const noexcept {
    const auto cursor = text_.cursor();
    const auto repeat = count();

    // cw on a word changes to its end, as vim does.
    if (operator_ == 'c' && !blank(cursor)) {
      auto end = runEnd(cursor, big);

      for (std::size_t index = 1; index < repeat; ++index) {
        end = endOfWord(end, big);
      }

      return Motion{.target = end, .inclusive = true};
    }

    auto position = cursor;
    auto last = cursor;

    for (std::size_t index = 0; index < repeat; ++index) {
      last = position;
      position = nextWord(position, big);
    }

    // With an operator, the last word moved over ends the text when it ends its line, as vim
    // has it: dw on a line's last word does not join the next line.
    if (operator_ != 0 && position > text_.lineEnd(last)) {
      position = text_.lineEnd(last);
    }

    return Motion{.target = position};
  }

  Editor::Motion Editor::lineEndMotion() const noexcept {
    const auto repeat = count();
    auto line = text_.lineStart(text_.cursor());

    for (std::size_t index = 1; index < repeat && text_.lineEnd(line) < text_.size(); ++index) {
      line = text_.lineEnd(line) + 1;
    }

    const auto end = text_.lineEnd(line);

    // An empty line has no character for $ to reach: the motion covers nothing, not its newline.
    if (end == line) {
      return Motion{.target = end};
    }

    return Motion{.target = text_.previous(end), .inclusive = true};
  }

  Editor::Motion Editor::lineMotion(bool down) const noexcept {
    const auto cursor = text_.cursor();
    const auto repeat = count();
    auto line = text_.lineStart(cursor);

    for (std::size_t index = 0; index < repeat; ++index) {
      // A count past the last line goes as far as there are lines; none at all moves nowhere.
      const bool edge = down ? text_.lineEnd(line) == text_.size() : line == 0;
      if (edge) {
        if (index == 0) {
          return Motion{.target = cursor, .inclusive = false, .linewise = true, .valid = false};
        }

        break;
      }

      line = down ? text_.lineEnd(line) + 1 : text_.lineStart(line - 1);
    }

    return Motion{.target = text_.atColumn({.line_start = line, .column = text_.column(cursor)}), .inclusive = false, .linewise = true};
  }

  char Editor::reversed(char kind) noexcept {
    switch (kind) {
    case 'f':
      return 'F';
    case 'F':
      return 'f';
    case 't':
      return 'T';
    default:
      return 't';
    }
  }

  std::size_t Editor::firstNonBlank(std::size_t line) const noexcept {
    auto position = line;
    const auto end = text_.lineEnd(line);

    while (position < end && blank(position)) {
      position = text_.next(position);
    }

    return position;
  }

  std::size_t Editor::lineAt(std::size_t index) const noexcept {
    std::size_t line = 0;

    for (std::size_t current = 0; current < index && text_.lineEnd(line) < text_.size(); ++current) {
      line = text_.lineEnd(line) + 1;
    }

    return line;
  }

  Editor::Motion Editor::findMotion(Find find, std::size_t repeat, bool repeated) const {
    ds::Array<char, 4> encoded{};
    const auto bytes = encode(find.target, encoded);
    const auto needle = std::string_view{encoded.data(), bytes};
    const auto cursor = text_.cursor();
    const auto start = text_.lineStart(cursor);
    const auto end = text_.lineEnd(cursor);
    const bool forward = find.kind == 'f' || find.kind == 't';
    auto position = cursor;

    for (std::size_t index = 0; index < repeat; ++index) {
      // Repeating t with ; skips the character it stopped before.
      const bool skip = repeated && index == 0 && (find.kind == 't' || find.kind == 'T');
      const auto found = forward ? findAfter(position, needle, skip, end) : findBefore(position, needle, skip, start);
      if (!found) {
        return Motion{.target = cursor, .valid = false};
      }

      position = *found;
    }

    if (find.kind == 't') {
      position = text_.previous(position);
    } else if (find.kind == 'T') {
      position = text_.next(position);
    }

    return Motion{.target = position, .inclusive = forward};
  }

  ds::Option<std::size_t> Editor::findAfter(std::size_t position, std::string_view needle, bool skip, std::size_t end) const {
    const auto view = text_.view();
    auto from = text_.next(position);
    if (skip && from < end && view.substr(from, needle.size()) == needle) {
      from = text_.next(from);
    }

    const auto found = view.find(needle, from);
    if (found == std::string_view::npos || found >= end) {
      return ds::none;
    }

    return found;
  }

  ds::Option<std::size_t> Editor::findBefore(std::size_t position, std::string_view needle, bool skip, std::size_t start) const {
    const auto view = text_.view();
    auto from = text_.previous(position);

    // As findAfter does: the character right before the cursor, which T stopped after, is passed.
    if (skip && position > start && view.substr(from, needle.size()) == needle) {
      if (from <= start) {
        return ds::none;
      }

      from = text_.previous(from);
    }

    const auto found = position <= start ? std::string_view::npos : view.rfind(needle, from);
    if (found == std::string_view::npos || found < start) {
      return ds::none;
    }

    return found;
  }

  Editor::Motion Editor::matchingBracket(std::size_t cursor) const noexcept {
    constexpr std::string_view open = "([{";
    constexpr std::string_view close = ")]}";
    const auto view = text_.view();
    auto position = cursor;
    const auto end = text_.lineEnd(cursor);

    while (position < end && !open.contains(view[position]) && !close.contains(view[position])) {
      ++position;
    }

    if (position >= end) {
      return Motion{.target = cursor, .valid = false};
    }

    const auto here = view[position];
    const auto opening = open.find(here);
    const char other = opening != std::string_view::npos ? close[opening] : open[close.find(here)];
    const int step = opening != std::string_view::npos ? 1 : -1;
    int depth = 0;

    for (auto index = static_cast<std::ptrdiff_t>(position); index >= 0 && std::cmp_less(index, view.size()); index += step) {
      const auto byte = view[static_cast<std::size_t>(index)];

      if (byte == here) {
        ++depth;
      } else if (byte == other) {
        --depth;
      }

      if (depth == 0) {
        return Motion{.target = static_cast<std::size_t>(index), .inclusive = true};
      }
    }

    return Motion{.target = cursor, .valid = false};
  }

  Request Editor::applyMotion(Motion motion) {
    pending_ = Pending::none;
    if (!motion.valid) {
      reset();
      return Request::none;
    }

    if (operator_ != 0) {
      const auto cursor = text_.cursor();
      const auto start = std::min(cursor, motion.target);
      auto end = std::max(cursor, motion.target);

      if (motion.inclusive) {
        end = text_.next(end);
      }

      operate(start, end, motion.linewise);
      return Request::none;
    }

    const bool visual = mode_ == Mode::visual || mode_ == Mode::visual_line;

    text_.moveTo(motion.target, visual);
    if (!visual) {
      clampNormal();
    }

    reset();
    return Request::none;
  }

  Request Editor::applyTextObject(char32_t character) {
    pending_ = Pending::none;
    const auto range = textObject(character, text_object_inner_);
    if (!range) {
      reset();
      return Request::none;
    }

    if (operator_ != 0) {
      operate(range->first, range->second, false);
      return Request::none;
    }

    text_.select(range->first, range->second == range->first ? range->first : text_.previous(range->second));
    reset();
    return Request::none;
  }

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::textObject(char32_t character, bool inner) const {
    switch (character) {
    case 'w':
    case 'W':
      return wordObject(character == 'W', inner);
    case '"':
    case '\'':
    case '`':
      return quoteObject(static_cast<char>(character), inner);
    case '(':
    case ')':
    case 'b':
      return bracketObject('(', ')', inner);
    case '[':
    case ']':
      return bracketObject('[', ']', inner);
    case '{':
    case '}':
    case 'B':
      return bracketObject('{', '}', inner);
    case '<':
    case '>':
      return bracketObject('<', '>', inner);
    default:
      return ds::none;
    }
  }

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::wordObject(bool big, bool inner) const {
    const auto cursor = text_.cursor();
    const auto view = text_.view();
    if (cursor >= view.size()) {
      return ds::none;
    }

    const auto run = kind(cursor, big);
    auto start = cursor;

    while (start > 0 && kind(text_.previous(start), big) == run) {
      start = text_.previous(start);
    }

    auto end = cursor;

    while (end < view.size() && kind(end, big) == run) {
      end = text_.next(end);
    }

    if (inner) {
      return std::pair{start, end};
    }

    // The blanks after the word, or before it when none follow, on the same line.
    const auto inline_blank = [&](std::size_t offset) {
      return blank(offset) && view[offset] != '\n';
    };

    if (end < view.size() && inline_blank(end)) {
      while (end < view.size() && inline_blank(end)) {
        end = text_.next(end);
      }
    } else {
      while (start > 0 && inline_blank(text_.previous(start))) {
        start = text_.previous(start);
      }
    }

    return std::pair{start, end};
  }

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::quoteObject(char quote, bool inner) const {
    const auto cursor = text_.cursor();
    const auto view = text_.view();
    const auto line = text_.lineStart(cursor);
    const auto end = text_.lineEnd(cursor);
    auto open = view.rfind(quote, cursor);
    std::size_t close = std::string_view::npos;

    if (open != std::string_view::npos && open >= line) {
      close = view.find(quote, open == cursor ? cursor + 1 : std::max(open + 1, cursor));
      if (open == cursor && (close == std::string_view::npos || close >= end)) {
        close = open;
        open = view.rfind(quote, cursor == 0 ? std::string_view::npos : cursor - 1);
      }
    } else {
      open = view.find(quote, cursor);
      close = open == std::string_view::npos ? open : view.find(quote, open + 1);
    }

    if (open == std::string_view::npos || close == std::string_view::npos || open < line || close >= end || close <= open) {
      return ds::none;
    }

    return inner ? std::pair{open + 1, close} : std::pair{open, close + 1};
  }

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::bracketObject(char open, char close, bool inner) const {
    const auto view = text_.view();
    const auto cursor = std::min(text_.cursor(), view.empty() ? 0 : view.size() - 1);
    int depth = 0;
    ds::Option<std::size_t> start;

    for (auto index = static_cast<std::ptrdiff_t>(cursor); index >= 0; --index) {
      const auto byte = view[static_cast<std::size_t>(index)];
      if (byte == close && std::cmp_not_equal(index, cursor)) {
        ++depth;
      } else if (byte == open) {
        if (depth == 0) {
          start = static_cast<std::size_t>(index);
          break;
        }

        --depth;
      }
    }

    if (!start) {
      return ds::none;
    }

    depth = 0;
    for (auto index = *start; index < view.size(); ++index) {
      // `open` and `close` differ, so a byte is at most one of them.
      depth += static_cast<int>(view[index] == open) - static_cast<int>(view[index] == close);
      if (depth == 0) {
        return inner ? std::pair{*start + 1, index} : std::pair{*start, index + 1};
      }
    }

    return ds::none;
  }

  void Editor::operate(std::size_t start, std::size_t end, bool linewise) {
    const auto action = operator_;
    const auto cursor = text_.cursor();
    // Only what deletes, changes or yanks fills a register; case and indent leave it alone.
    const bool stores = action == 'd' || action == 'c' || action == 'y';

    if (linewise) {
      start = text_.lineStart(start);
      end = text_.lineEnd(end);

      // A linewise register holds whole lines, each with its newline, whichever newline the
      // edit takes.
      if (stores) {
        ds::String<Memory> lines{memory(), text_.view().substr(start, end - start)};

        lines.push('\n');
        store(lines, true);
      }

      if (end < text_.size()) {
        ++end;
      } else if (start > 0 && action == 'd') {
        // Deleting the last line takes the newline before it instead.
        --start;
      }
    } else if (stores) {
      store(text_.view().substr(start, end - start), false);
    }

    switch (action) {
    case 'd':
      text_.replace(start, end, {});
      text_.moveTo(linewise ? firstNonBlank(text_.lineStart(std::min(start, text_.size()))) : start);
      mode_ = Mode::normal;
      clampNormal();
      finishRecording();
      break;
    case 'c':
      if (linewise && end > start && text_.view()[end - 1] == '\n') {
        --end;
      }

      // What it deletes and what is typed after it undo as one step.
      text_.hold();
      text_.replace(start, end, {});
      mode_ = Mode::insert;
      break;
    case 'y':
      // A yank of the lines the cursor is on leaves it there, as yy and Y do.
      if (!linewise || cursor < start || cursor >= end) {
        text_.moveTo(start);
      }

      mode_ = Mode::normal;
      clampNormal();
      break;
    case '>':
    case '<':
      indent(start, end, action == '>');
      mode_ = Mode::normal;
      finishRecording();
      break;
    case '~':
    case 'u':
    case 'U':
      changeCase(start, end, action);
      mode_ = Mode::normal;
      finishRecording();
      break;
    default:
      break;
    }

    reset();
  }

  void Editor::indent(std::size_t start, std::size_t end, bool right) {
    const auto first = text_.lineStart(start);
    const auto last = text_.lineEnd(end > first ? end - 1 : first);
    const auto view = text_.view();
    ds::String<Memory> result{memory()};

    for (auto line = first;;) {
      const auto line_end = text_.lineEnd(line);
      auto content = view.substr(line, line_end - line);
      if (right && !content.empty()) {
        result.append("  ");
      } else if (!right) {
        const auto spaces = std::min<std::size_t>(content.find_first_not_of(' ') == std::string_view::npos ? content.size() : content.find_first_not_of(' '), 2);

        content.remove_prefix(spaces);
      }

      result.append(content);
      if (line_end >= last) {
        break;
      }

      result.push('\n');
      line = line_end + 1;
    }

    text_.replace(first, last, result);
    text_.moveTo(firstNonBlank(first));
  }

  void Editor::changeCase(std::size_t start, std::size_t end, char action) {
    // ASCII's lowercase letters sit this far after the uppercase ones.
    constexpr char case_distance = 'a' - 'A';
    ds::String<Memory> changed{memory(), text_.view().substr(start, end - start)};

    for (auto& byte : changed.viewMut()) {
      const bool lower = byte >= 'a' && byte <= 'z';
      const bool upper = byte >= 'A' && byte <= 'Z';

      if ((action == 'U' || action == '~') && lower) {
        byte = static_cast<char>(byte - case_distance);
      } else if ((action == 'u' || action == '~') && upper) {
        byte = static_cast<char>(byte + case_distance);
      }
    }

    text_.replace(start, end, changed);
    text_.moveTo(start);
  }

  void Editor::store(std::string_view text, bool linewise) {
    if (register_ == '+' || register_ == '*') {
      if (clipboard_.write) {
        clipboard_.write(text);
      }
    } else if (register_ != '_') {
      auto& target = register_ >= 'a' && register_ <= 'z' ? registers_.atMut(static_cast<std::size_t>(register_ - 'a')) : unnamed_;

      target.text.assign(text);
      target.linewise = linewise;
      if (register_ != '"') {
        unnamed_.text.assign(target.text);
        unnamed_.linewise = target.linewise;
      }
    }
  }

  Editor::Loaded Editor::load() {
    if (register_ == '+' || register_ == '*') {
      pasted_.clear();
      if (clipboard_.read) {
        clipboard_.read(pasted_);
      }

      return {.text = pasted_.view(), .linewise = false};
    }

    const auto& source = register_ >= 'a' && register_ <= 'z' ? registers_[static_cast<std::size_t>(register_ - 'a')] : unnamed_;

    return {.text = source.text.view(), .linewise = source.linewise};
  }

  void Editor::put(bool before) {
    const auto value = load();
    if (value.text.empty()) {
      return;
    }

    // What could never fit is not built: a count of copies past the text's capacity puts none.
    const auto room = Text::capacity - std::min(text_.size(), Text::capacity);
    if (value.text.size() + 1 > room / count()) {
      return;
    }

    ds::String<Memory> text{memory()};

    for (std::size_t index = 0; index < count(); ++index) {
      text.append(value.text);
    }

    const auto cursor = text_.cursor();

    if (value.linewise) {
      if (!text.view().ends_with('\n')) {
        text.push('\n');
      }

      if (before) {
        const auto line = text_.lineStart(cursor);

        text_.replace(line, line, text);
        text_.moveTo(firstNonBlank(line));
      } else {
        const auto end = text_.lineEnd(cursor);
        if (end == text_.size()) {
          text.truncate(text.size() - 1);
          text.insert(0, "\n");
          text_.replace(end, end, text);
          text_.moveTo(firstNonBlank(end + 1));
        } else {
          text_.replace(end + 1, end + 1, text);
          text_.moveTo(firstNonBlank(end + 1));
        }
      }
    } else {
      const auto position = before || text_.empty() || cursor == text_.lineEnd(cursor) ? cursor : text_.next(cursor);

      text_.replace(position, position, text);
      text_.moveTo(text_.previous(position + text.size()));
    }

    clampNormal();
  }

  void Editor::replaceCharacters(std::string_view typed) {
    pending_ = Pending::none;
    const auto cursor = text_.cursor();
    auto end = cursor;

    for (std::size_t index = 0; index < count(); ++index) {
      if (end >= text_.lineEnd(cursor)) {
        reset();
        return;
      }

      end = text_.next(end);
    }

    ds::String<Memory> text{memory()};

    for (std::size_t index = 0; index < count(); ++index) {
      text.append(typed);
    }

    text_.replace(cursor, end, text);
    text_.moveTo(text_.previous(cursor + text.size()));
    reset();
    finishRecording();
  }

  Request Editor::command(char32_t character, const KeyPress& key) {
    const auto cursor = text_.cursor();
    const bool visual = mode_ == Mode::visual || mode_ == Mode::visual_line;
    if (visual) {
      return visualCommand(character);
    }

    if (operator_ != 0) {
      secondOperator(character);
      return Request::none;
    }

    switch (character) {
    case 'd':
    case 'c':
    case 'y':
    case '>':
    case '<':
      if (character != 'y') {
        startRecording(key);
      }

      operator_ = static_cast<char>(character);
      return Request::none;
    case '"':
      register_pending_ = true;
      return Request::none;
    case 'i':
    case 'a':
    case 'I':
    case 'A':
      startRecording(key);
      enterInsert(insertPosition(character));
      return Request::none;
    case 'o':
    case 'O':
      startRecording(key);
      openLine(character == 'O');
      return Request::none;
    case 'x':
    case 'X':
      startRecording(key);
      deleteCharacters(character == 'X');
      return Request::none;
    case 's':
      // cl: the characters under the cursor.
      startRecording(key);
      operator_ = 'c';
      return applyMotion(*motionFor('l'));
    case 'S':
    case 'C':
    case 'D':
    case 'Y':
      operateToLineEnd(character, key);
      return Request::none;
    case 'p':
    case 'P':
      startRecording(key);
      put(character == 'P');
      reset();
      finishRecording();
      return Request::none;
    case 'r':
      startRecording(key);
      pending_ = Pending::replace;
      return Request::none;
    case '~':
      startRecording(key);
      toggleCase();
      return Request::none;
    case 'J':
      startRecording(key);
      joinLines();
      return Request::none;
    case 'u':
      undoChanges();
      return Request::none;
    case '.':
      // Repeated once the key is done: the keys it replays come through `dispatch`, not here.
      repeat_requested_ = true;
      return Request::none;
    case 'v':
    case 'V':
      mode_ = character == 'v' ? Mode::visual : Mode::visual_line;
      text_.select(cursor, cursor);
      reset();
      return Request::none;
    case 'n':
    case 'N':
      reset();
      return character == 'n' ? Request::history_previous : Request::history_next;
    case '/':
    case '?':
      reset();
      return Request::history_search;
    default:
      reset();
      return Request::none;
    }
  }

  void Editor::secondOperator(char32_t character) {
    // An operator typed twice acts on whole lines.
    if (static_cast<char>(character) == operator_ || (operator_ == 'g' && character == '~')) {
      operateOnLines();
    } else {
      reset();
    }
  }

  std::size_t Editor::insertPosition(char32_t character) const noexcept {
    const auto cursor = text_.cursor();

    switch (character) {
    case 'a':
      return cursor < text_.lineEnd(cursor) ? text_.next(cursor) : cursor;
    case 'I':
      return firstNonBlank(text_.lineStart(cursor));
    case 'A':
      return text_.lineEnd(cursor);
    default:
      return cursor;
    }
  }

  void Editor::operateOnLines() {
    const auto cursor = text_.cursor();
    const auto lines = count() - 1;
    auto last = cursor;

    for (std::size_t index = 0; index < lines && text_.lineEnd(last) < text_.size(); ++index) {
      last = text_.lineEnd(last) + 1;
    }

    operate(cursor, last, true);
  }

  void Editor::openLine(bool above) {
    const auto cursor = text_.cursor();

    text_.hold();

    if (above) {
      const auto start = text_.lineStart(cursor);

      text_.replace(start, start, "\n");
      text_.moveTo(start);
    } else {
      const auto end = text_.lineEnd(cursor);

      text_.replace(end, end, "\n");
    }

    mode_ = Mode::insert;
  }

  void Editor::deleteCharacters(bool backward) {
    const auto cursor = text_.cursor();
    auto start = cursor;
    auto end = cursor;

    for (std::size_t index = 0; index < count(); ++index) {
      if (!backward && end < text_.lineEnd(cursor)) {
        end = text_.next(end);
      } else if (backward && start > text_.lineStart(cursor)) {
        start = text_.previous(start);
      }
    }

    if (start != end) {
      store(text_.view().substr(start, end - start), false);
      text_.replace(start, end, {});
      text_.moveTo(start);
    }

    clampNormal();
    reset();
    finishRecording();
  }

  void Editor::operateToLineEnd(char32_t character, const KeyPress& key) {
    if (character != 'Y') {
      startRecording(key);
    }

    // S and C change, D deletes and Y yanks; S and Y take whole lines.
    operator_ = 'c';
    if (character == 'D') {
      operator_ = 'd';
    } else if (character == 'Y') {
      operator_ = 'y';
    }

    if (character == 'S' || character == 'Y') {
      operateOnLines();
      return;
    }

    const auto cursor = text_.cursor();

    operate(cursor, text_.lineEnd(cursor), false);
  }

  void Editor::toggleCase() {
    const auto cursor = text_.cursor();
    auto end = cursor;

    for (std::size_t index = 0; index < count() && end < text_.lineEnd(cursor); ++index) {
      end = text_.next(end);
    }

    operator_ = '~';
    operate(cursor, end, false);
    text_.moveTo(end);
    clampNormal();
  }

  void Editor::joinLines() {
    for (std::size_t index = 0; index < std::max<std::size_t>(1, count() - (count_ > 1 ? 1 : 0)); ++index) {
      const auto newline = text_.lineEnd(text_.cursor());
      if (newline >= text_.size()) {
        break;
      }

      // The newline and the blanks that indent the next line become one space.
      auto content = newline + 1;

      while (content < text_.size() && blank(content) && text_.view()[content] != '\n') {
        ++content;
      }

      text_.replace(newline, content, " ");
      text_.moveTo(newline);
    }

    reset();
    finishRecording();
  }

  void Editor::undoChanges() {
    for (std::size_t index = 0; index < count(); ++index) {
      text_.undo();
    }

    reset();
    clampNormal();
  }

  Request Editor::visualCommand(char32_t character) {
    // Read before the cursor moves: moving it collapses the selection. What the commands take is
    // what the mode highlights.
    const auto [start, end] = *visualRange();
    const bool lines = mode_ == Mode::visual_line;

    switch (character) {
    case 'd':
    case 'x':
    case 'c':
    case 's':
    case 'y':
    case '>':
    case '<':
    case '~':
    case 'u':
    case 'U': {
      operator_ = static_cast<char>(character);
      if (character == 'x') {
        operator_ = 'd';
      } else if (character == 's') {
        operator_ = 'c';
      }

      mode_ = Mode::normal;
      text_.moveTo(start);
      operate(start, end, lines);
      return Request::none;
    }
    case 'o': {
      const auto anchor = text_.anchor();

      text_.select(text_.cursor(), anchor);
      return Request::none;
    }
    case 'v':
    case 'V':
      if ((character == 'v') == (mode_ == Mode::visual)) {
        mode_ = Mode::normal;
        text_.moveTo(text_.cursor());
      } else {
        mode_ = character == 'v' ? Mode::visual : Mode::visual_line;
      }

      return Request::none;
    case 'p':
    case 'P':
      return visualPut(start, end, lines);
    default:
      reset();
      return Request::none;
    }
  }

  // Visual mode's p and P: the selection's text is replaced by the register's, and goes to the
  // unnamed register.
  Request Editor::visualPut(std::size_t start, std::size_t end, bool lines) {
    // Copied: storing the replaced text may overwrite the register it comes from.
    const auto loaded = load();
    const ds::String<Memory> value{memory(), loaded.text};
    const auto from = start;
    auto until = end;

    ds::String<Memory> replaced{memory(), text_.view().substr(from, until - from)};
    ds::String<Memory> put{memory()};

    // Whole lines for whole lines; a line register over characters goes on lines of its own.
    if (lines) {
      const bool through_newline = until < text_.size();

      replaced.push('\n');
      put.assign(value);
      if (!put.view().ends_with('\n')) {
        put.push('\n');
      }

      if (through_newline) {
        ++until;
      } else {
        put.truncate(put.size() - 1);
      }
    } else if (loaded.linewise) {
      put.push('\n');
      put.append(value);
    } else {
      put.assign(value);
    }

    text_.replace(from, until, put);
    // The text it replaced is the unnamed register's, as vim keeps it.
    register_ = '"';
    store(replaced, lines);
    mode_ = Mode::normal;
    text_.moveTo(lines || loaded.linewise ? firstNonBlank(text_.lineStart(std::min(from + (lines ? 0 : 1), text_.size()))) : text_.cursor());
    clampNormal();
    reset();
    return Request::none;
  }

  void Editor::startRecording(const KeyPress& key) {
    if (replaying_ != 0) {
      return;
    }

    recording_ = true;
    recorded_.clear();
    if (count_ != 0) {
      // Room for any std::size_t in decimal.
      constexpr std::size_t count_digits = 24;
      ds::Array<char, count_digits> digits{};
      auto* const end = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), count_).ptr;

      for (const auto digit : std::string_view{digits.data(), end}) {
        recorded_.push(Recorded{
            .key = KeyPress{.key = Key::character, .character = static_cast<char32_t>(digit)},
            .text = ds::String<Memory>{recorded_.memory()},
        });
      }
    }

    record(key);
  }

  void Editor::record(const KeyPress& key) {
    constexpr std::size_t maximum_recorded_keys = 4096;
    if (recorded_.size() >= maximum_recorded_keys) {
      recording_ = false;
      recorded_.clear();
      return;
    }

    // The key's text views the input it came with, which ends after this key: the recording keeps a
    // copy of it, and the key without it.
    auto kept = key;

    kept.text = {};
    recorded_.push(Recorded{.key = kept, .text = ds::String<Memory>{recorded_.memory(), key.text}});
  }

  void Editor::finishRecording() {
    if (replaying_ == 0 && recording_) {
      recording_ = false;
      last_change_ = recorded_.clone();
    }
  }

  void Editor::repeat() {
    repeat_requested_ = false;
    // A count typed before the dot replaces the change's own.
    const auto given = count_;
    // Copied: pressing the keys records them again.
    const auto changes = last_change_.clone();
    std::size_t first = 0;

    ++replaying_;
    reset();
    if (given != 0) {
      const auto digit = [&](std::size_t index) {
        const auto& key = changes[index].key;

        return key.key == Key::character && !key.modifiers.control && key.character >= (index == 0 ? U'1' : U'0') && key.character <= U'9';
      };

      while (first < changes.size() && digit(first)) {
        ++first;
      }

      // Room for any std::size_t in decimal.
      constexpr std::size_t count_digits = 24;
      ds::Array<char, count_digits> digits{};
      auto* const end = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), given).ptr;

      for (const auto character : std::string_view{digits.data(), end}) {
        dispatch(KeyPress{.key = Key::character, .character = static_cast<char32_t>(character)});
      }
    }

    for (std::size_t index = first; index < changes.size(); ++index) {
      auto key = changes[index].key;

      key.text = changes[index].text;
      dispatch(key);
    }

    // A dot among the keys it replays repeats nothing more.
    repeat_requested_ = false;
    if (mode_ == Mode::insert) {
      enterNormal();
    }

    --replaying_;
  }

  namespace {

    // UTF-8: the first code point each length takes, the tag of the lead byte for that length,
    // and the six bits under the tag of every byte after it.
    constexpr char32_t first_two_byte = 0x80;
    constexpr char32_t first_three_byte = 0x800;
    constexpr char32_t first_four_byte = 0x10000;
    constexpr char32_t two_byte_lead = 0xc0;
    constexpr char32_t three_byte_lead = 0xe0;
    constexpr char32_t four_byte_lead = 0xf0;
    constexpr char32_t continuation_tag = 0x80;
    constexpr char32_t continuation_mask = 0x3f;
    constexpr unsigned continuation_shift = 6;

    constexpr char continuation(char32_t value, unsigned shift) noexcept {
      return static_cast<char>(continuation_tag | ((value >> shift) & continuation_mask));
    }

  }

  std::size_t Editor::encode(char32_t value, ds::Array<char, 4>& output) noexcept {
    if (value < first_two_byte) {
      output.atMut(0) = static_cast<char>(value);
      return 1;
    }

    if (value < first_three_byte) {
      output.atMut(0) = static_cast<char>(two_byte_lead | (value >> continuation_shift));
      output.atMut(1) = continuation(value, 0);
      return 2;
    }

    if (value < first_four_byte) {
      output.atMut(0) = static_cast<char>(three_byte_lead | (value >> (2 * continuation_shift)));
      output.atMut(1) = continuation(value, continuation_shift);
      output.atMut(2) = continuation(value, 0);
      return 3;
    }

    output.atMut(0) = static_cast<char>(four_byte_lead | (value >> (3 * continuation_shift)));
    output.atMut(1) = continuation(value, 2 * continuation_shift);
    output.atMut(2) = continuation(value, continuation_shift);
    output.atMut(3) = continuation(value, 0);
    return 4;
  }

}
