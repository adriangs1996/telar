module telar.gui.features.prompt;

import std;
import telar.base.ds;

namespace telar::gui::features::prompt {

  Editor::Editor(Keymap keymap)
      : keymap_(keymap) {}

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

  bool Editor::pending() const noexcept {
    return count_ != 0 || operator_ != 0 || pending_ != Pending::none || register_pending_;
  }

  void Editor::setClipboard(Clipboard clipboard) {
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
        reset();
      }

      return Request::none;
    }

    return Request::unhandled;
  }

  Request Editor::press(const KeyPress& key) {
    if (keymap_ == Keymap::vim && mode_ != Mode::insert) {
      if (replaying_ == 0 && recording_) {
        record(key);
      }

      return normal(key);
    }

    if (keymap_ == Keymap::vim && replaying_ == 0 && recording_) {
      record(key);
    }

    return insert(key);
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
      if (text_.selecting()) {
        text_.insert({});
      } else if (mods.alt || mods.control) {
        killBackward(wordStart(cursor, false));
      } else {
        text_.replace(text_.previous(cursor), cursor, {}, true);
      }

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

    move(text_.atColumn(target_start, column), extend);
    goal_column_ = column;
    return Request::none;
  }

  void Editor::kill(std::size_t start, std::size_t end) {
    if (start == end) {
      return;
    }

    kill_ring_.assign(text_.view().substr(start, end - start));
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
    std::string swapped{view.substr(cursor, after - cursor)};

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

  std::size_t Editor::endOfWord(std::size_t offset, bool big) const noexcept {
    auto position = text_.next(offset);

    while (position < text_.size() && blank(position)) {
      position = text_.next(position);
    }

    if (position >= text_.size()) {
      return text_.size() == 0 ? 0 : text_.previous(text_.size());
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
    text_.seal();
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

    char32_t character = key.character;

    switch (key.key) {
    case Key::left:
      character = 'h';
      break;
    case Key::right:
      character = 'l';
      break;
    case Key::up:
      character = 'k';
      break;
    case Key::down:
      character = 'j';
      break;
    case Key::home:
      character = '0';
      break;
    case Key::end:
      character = '$';
      break;
    case Key::backspace:
      character = 'h';
      break;
    case Key::delete_forward:
      character = 'x';
      break;
    case Key::tab:
      return Request::complete;
    case Key::character:
      break;
    default:
      return Request::unhandled;
    }

    if (register_pending_) {
      register_ = static_cast<char>(character);
      register_pending_ = false;
      return Request::none;
    }

    if (pending_ == Pending::replace) {
      replaceCharacters(key.text);
      return Request::none;
    }

    if (pending_ == Pending::find) {
      last_find_ = {find_kind_, character};
      return applyMotion(findMotion(find_kind_, character, count()));
    }

    if (pending_ == Pending::g) {
      pending_ = Pending::none;
      if (character == 'g') {
        return applyMotion({0, false, true});
      }

      if (character == 'e' || character == 'E') {
        return applyMotion({wordStart(text_.cursor(), character == 'E'), true});
      }

      reset();
      return Request::none;
    }

    if (pending_ == Pending::text_object) {
      return applyTextObject(character);
    }

    if ((character >= '1' && character <= '9') || (character == '0' && (operator_ != 0 ? operator_count_ : count_) != 0)) {
      auto& target = operator_ != 0 ? operator_count_ : count_;

      target = std::min<std::size_t>(target * 10 + (character - '0'), 9999);
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

  ds::Option<Editor::Motion> Editor::motionFor(char32_t character) const noexcept {
    const auto cursor = text_.cursor();
    const auto repeat = count();
    auto apply = [&](auto step) {
      auto position = cursor;

      for (std::size_t index = 0; index < repeat; ++index) {
        position = step(position);
      }

      return position;
    };

    switch (character) {
    case 'h':
      return Motion{apply([&](std::size_t at) {
        return at > text_.lineStart(cursor) ? text_.previous(at) : at;
      })};
    case 'l':
    case ' ':
      return Motion{apply([&](std::size_t at) {
        return at < text_.lineEnd(cursor) ? text_.next(at) : at;
      })};
    case 'w':
    case 'W':
      // cw on a word changes to its end, as vim does.
      if (operator_ == 'c' && !blank(cursor)) {
        auto end = runEnd(cursor, character == 'W');

        for (std::size_t index = 1; index < repeat; ++index) {
          end = endOfWord(end, character == 'W');
        }

        return Motion{end, true};
      }

      return Motion{apply([&](std::size_t at) {
        return nextWord(at, character == 'W');
      })};
    case 'b':
    case 'B':
      return Motion{apply([&](std::size_t at) {
        return wordStart(at, character == 'B');
      })};
    case 'e':
    case 'E':
      return Motion{apply([&](std::size_t at) {
                      return endOfWord(at, character == 'E');
                    }),
          true};
    case '0':
      return Motion{text_.lineStart(cursor)};
    case '^':
      return Motion{firstNonBlank(text_.lineStart(cursor))};
    case '$': {
      auto line = text_.lineStart(cursor);

      for (std::size_t index = 1; index < repeat && text_.lineEnd(line) < text_.size(); ++index) {
        line = text_.lineEnd(line) + 1;
      }

      const auto end = text_.lineEnd(line);

      return Motion{end > line ? text_.previous(end) : end, true};
    }
    case 'G': {
      if (count_ == 0 && operator_count_ == 0) {
        return Motion{text_.lineStart(text_.size()), false, true};
      }

      return Motion{lineAt(repeat - 1), false, true};
    }
    case 'j':
    case 'k': {
      auto line = text_.lineStart(cursor);

      for (std::size_t index = 0; index < repeat; ++index) {
        if (character == 'j') {
          if (text_.lineEnd(line) == text_.size()) {
            return Motion{cursor, false, true, operator_ != 0 && index > 0};
          }

          line = text_.lineEnd(line) + 1;
        } else {
          if (line == 0) {
            return Motion{cursor, false, true, operator_ != 0 && index > 0};
          }

          line = text_.lineStart(line - 1);
        }
      }

      return Motion{text_.atColumn(line, text_.column(cursor)), false, true};
    }
    case ';':
    case ',':
      if (last_find_.second == 0) {
        return Motion{cursor, false, false, false};
      }

      return findMotion(character == ';' ? last_find_.first : reversed(last_find_.first), last_find_.second, repeat, true);
    case '%':
      return matchingBracket(cursor);
    default:
      return ds::none;
    }
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

  Editor::Motion Editor::findMotion(char kind, char32_t target, std::size_t repeat, bool repeated) const {
    ds::Array<char, 4> encoded{};
    const auto bytes = encode(target, encoded);
    const auto needle = std::string_view{encoded.data(), bytes};
    const auto view = text_.view();
    const auto cursor = text_.cursor();
    const auto start = text_.lineStart(cursor);
    const auto end = text_.lineEnd(cursor);
    auto position = cursor;

    for (std::size_t index = 0; index < repeat; ++index) {
      if (kind == 'f' || kind == 't') {
        auto from = text_.next(position);
        // Repeating t with ; skips the character it stopped before.
        if (repeated && kind == 't' && index == 0 && from < end && view.substr(from, needle.size()) == needle) {
          from = text_.next(from);
        }

        const auto found = view.find(needle, from);
        if (found == std::string_view::npos || found >= end) {
          return Motion{cursor, false, false, false};
        }

        position = found;
      } else {
        auto from = text_.previous(position);
        if (repeated && kind == 'T' && index == 0 && from > start && view.substr(text_.previous(from), needle.size()) == needle) {
          from = text_.previous(from);
        }

        const auto found = position <= start ? std::string_view::npos : view.rfind(needle, from);
        if (found == std::string_view::npos || found < start) {
          return Motion{cursor, false, false, false};
        }

        position = found;
      }
    }

    if (kind == 't') {
      position = text_.previous(position);
    } else if (kind == 'T') {
      position = text_.next(position);
    }

    return Motion{position, kind == 'f' || kind == 't'};
  }

  Editor::Motion Editor::matchingBracket(std::size_t cursor) const noexcept {
    constexpr std::string_view open = "([{";
    constexpr std::string_view close = ")]}";
    const auto view = text_.view();
    auto position = cursor;
    const auto end = text_.lineEnd(cursor);

    while (position < end && open.find(view[position]) == std::string_view::npos && close.find(view[position]) == std::string_view::npos) {
      ++position;
    }

    if (position >= end) {
      return Motion{cursor, false, false, false};
    }

    const auto here = view[position];
    const auto opening = open.find(here);
    const char other = opening != std::string_view::npos ? close[opening] : open[close.find(here)];
    const int step = opening != std::string_view::npos ? 1 : -1;
    int depth = 0;

    for (auto index = static_cast<std::ptrdiff_t>(position); index >= 0 && index < static_cast<std::ptrdiff_t>(view.size()); index += step) {
      const auto byte = view[static_cast<std::size_t>(index)];

      depth += byte == here ? 1 : byte == other ? -1
                                                : 0;
      if (depth == 0) {
        return Motion{static_cast<std::size_t>(index), true};
      }
    }

    return Motion{cursor, false, false, false};
  }

  Request Editor::applyMotion(Motion motion) {
    pending_ = Pending::none;
    if (!motion.valid) {
      reset();
      return Request::none;
    }

    if (operator_ != 0) {
      const auto cursor = text_.cursor();
      auto start = std::min(cursor, motion.target);
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
    const auto cursor = text_.cursor();
    const auto view = text_.view();

    switch (character) {
    case 'w':
    case 'W': {
      const bool big = character == 'W';

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

      if (!inner) {
        if (end < view.size() && blank(end) && view[end] != '\n') {
          while (end < view.size() && blank(end) && view[end] != '\n') {
            end = text_.next(end);
          }
        } else {
          while (start > 0 && blank(text_.previous(start)) && view[text_.previous(start)] != '\n') {
            start = text_.previous(start);
          }
        }
      }

      return std::pair{start, end};
    }
    case '"':
    case '\'':
    case '`': {
      const auto quote = static_cast<char>(character);
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

  ds::Option<std::pair<std::size_t, std::size_t>> Editor::bracketObject(char open, char close, bool inner) const {
    const auto view = text_.view();
    const auto cursor = std::min(text_.cursor(), view.empty() ? 0 : view.size() - 1);
    int depth = 0;
    ds::Option<std::size_t> start;

    for (auto index = static_cast<std::ptrdiff_t>(cursor); index >= 0; --index) {
      const auto byte = view[static_cast<std::size_t>(index)];
      if (byte == close && static_cast<std::size_t>(index) != cursor) {
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
      depth += view[index] == open ? 1 : view[index] == close ? -1
                                                              : 0;
      if (depth == 0) {
        return inner ? std::pair{*start + 1, index} : std::pair{*start, index + 1};
      }
    }

    return ds::none;
  }

  void Editor::operate(std::size_t start, std::size_t end, bool linewise) {
    const auto action = operator_;

    if (linewise) {
      start = text_.lineStart(start);
      end = text_.lineEnd(end);
      if (end < text_.size()) {
        ++end;
      } else if (start > 0 && action == 'd') {
        // Deleting the last line takes the newline before it instead.
        --start;
      }
    }

    const auto view = text_.view();

    store(view.substr(start, end - start), linewise);
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

      text_.replace(start, end, {});
      mode_ = Mode::insert;
      break;
    case 'y':
      text_.moveTo(start);
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
    std::string result;

    for (auto line = first;;) {
      const auto line_end = text_.lineEnd(line);
      auto content = view.substr(line, line_end - line);
      if (right && !content.empty()) {
        result += "  ";
      } else if (!right) {
        const auto spaces = std::min<std::size_t>(content.find_first_not_of(' ') == std::string_view::npos ? content.size() : content.find_first_not_of(' '), 2);

        content.remove_prefix(spaces);
      }

      result += content;
      if (line_end >= last) {
        break;
      }

      result += '\n';
      line = line_end + 1;
    }

    text_.replace(first, last, result);
    text_.moveTo(firstNonBlank(first));
  }

  void Editor::changeCase(std::size_t start, std::size_t end, char action) {
    std::string changed{text_.view().substr(start, end - start)};

    for (auto& byte : changed) {
      const bool lower = byte >= 'a' && byte <= 'z';
      const bool upper = byte >= 'A' && byte <= 'Z';

      if ((action == 'U' || action == '~') && lower) {
        byte = static_cast<char>(byte - 32);
      } else if ((action == 'u' || action == '~') && upper) {
        byte = static_cast<char>(byte + 32);
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
      auto& target = register_ >= 'a' && register_ <= 'z' ? registers_.atMut(register_ - 'a') : unnamed_;

      target.text.assign(text);
      target.linewise = linewise;
      if (register_ != '"') {
        unnamed_ = target;
      }
    }
  }

  Editor::Register Editor::load() const {
    if (register_ == '+' || register_ == '*') {
      return {clipboard_.read ? clipboard_.read() : std::string{}, false};
    }

    if (register_ >= 'a' && register_ <= 'z') {
      return registers_[register_ - 'a'];
    }

    return unnamed_;
  }

  void Editor::put(bool before) {
    const auto value = load();
    if (value.text.empty()) {
      return;
    }

    std::string text;

    for (std::size_t index = 0; index < count(); ++index) {
      text += value.text;
    }

    const auto cursor = text_.cursor();

    if (value.linewise) {
      if (!text.ends_with('\n')) {
        text += '\n';
      }

      if (before) {
        const auto line = text_.lineStart(cursor);

        text_.replace(line, line, text);
        text_.moveTo(firstNonBlank(line));
      } else {
        const auto end = text_.lineEnd(cursor);
        if (end == text_.size()) {
          text.pop_back();
          text.insert(text.begin(), '\n');
          text_.replace(end, end, text);
          text_.moveTo(firstNonBlank(end + 1));
        } else {
          text_.replace(end + 1, end + 1, text);
          text_.moveTo(firstNonBlank(end + 1));
        }
      }
    } else {
      const auto at = before || text_.empty() || cursor == text_.lineEnd(cursor) ? cursor : text_.next(cursor);

      text_.replace(at, at, text);
      text_.moveTo(text_.previous(at + text.size()));
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

    std::string text;

    for (std::size_t index = 0; index < count(); ++index) {
      text += typed;
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

    // An operator typed twice acts on whole lines.
    if (operator_ != 0) {
      if (static_cast<char>(character) == operator_ || (operator_ == 'g' && character == '~')) {
        const auto lines = count() - 1;
        auto last = cursor;

        for (std::size_t index = 0; index < lines && text_.lineEnd(last) < text_.size(); ++index) {
          last = text_.lineEnd(last) + 1;
        }

        operate(cursor, last, true);
      } else {
        reset();
      }

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
      startRecording(key);
      enterInsert(cursor);
      return Request::none;
    case 'a':
      startRecording(key);
      enterInsert(cursor < text_.lineEnd(cursor) ? text_.next(cursor) : cursor);
      return Request::none;
    case 'I':
      startRecording(key);
      enterInsert(firstNonBlank(text_.lineStart(cursor)));
      return Request::none;
    case 'A':
      startRecording(key);
      enterInsert(text_.lineEnd(cursor));
      return Request::none;
    case 'o': {
      startRecording(key);
      const auto end = text_.lineEnd(cursor);

      text_.replace(end, end, "\n");
      mode_ = Mode::insert;
      return Request::none;
    }
    case 'O': {
      startRecording(key);
      const auto start = text_.lineStart(cursor);

      text_.replace(start, start, "\n");
      text_.moveTo(start);
      mode_ = Mode::insert;
      return Request::none;
    }
    case 'x':
    case 'X': {
      startRecording(key);
      auto start = cursor;
      auto end = cursor;

      for (std::size_t index = 0; index < count(); ++index) {
        if (character == 'x' && end < text_.lineEnd(cursor)) {
          end = text_.next(end);
        } else if (character == 'X' && start > text_.lineStart(cursor)) {
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
      return Request::none;
    }
    case 's':
      // cl: the characters under the cursor.
      startRecording(key);
      operator_ = 'c';
      return applyMotion(*motionFor('l'));
    case 'S':
    case 'C':
    case 'D':
    case 'Y': {
      if (character != 'Y') {
        startRecording(key);
      }

      operator_ = character == 'S' ? 'c' : character == 'C' ? 'c'
                                       : character == 'D'   ? 'd'
                                                            : 'y';
      if (character == 'S' || character == 'Y') {
        return command(static_cast<char32_t>(operator_), key);
      }

      const auto end = text_.lineEnd(cursor);

      operate(cursor, end, false);
      return Request::none;
    }
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
    case '~': {
      startRecording(key);
      auto end = cursor;

      for (std::size_t index = 0; index < count() && end < text_.lineEnd(cursor); ++index) {
        end = text_.next(end);
      }

      operator_ = '~';
      operate(cursor, end, false);
      text_.moveTo(end);
      clampNormal();
      return Request::none;
    }
    case 'J': {
      startRecording(key);
      for (std::size_t index = 0; index < std::max<std::size_t>(1, count() - (count_ > 1 ? 1 : 0)); ++index) {
        const auto end = text_.lineEnd(text_.cursor());
        if (end >= text_.size()) {
          break;
        }

        auto next = end + 1;

        while (next < text_.size() && blank(next) && text_.view()[next] != '\n') {
          ++next;
        }

        text_.replace(end, next, " ");
        text_.moveTo(end);
      }

      reset();
      finishRecording();
      return Request::none;
    }
    case 'u':
      for (std::size_t index = 0; index < count(); ++index) {
        text_.undo();
      }

      reset();
      clampNormal();
      return Request::none;
    case '.':
      repeat();
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

  Request Editor::visualCommand(char32_t character) {
    auto start = text_.selectionStart();
    auto end = text_.next(text_.selectionEnd());
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
      operator_ = character == 'x' ? 'd' : character == 's' ? 'c'
                                                            : static_cast<char>(character);
      mode_ = Mode::normal;
      text_.moveTo(start);
      operate(start, lines ? text_.selectionEnd() : end, lines);
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
    case 'P': {
      const auto value = load();

      text_.replace(start, end, value.text);
      mode_ = Mode::normal;
      clampNormal();
      return Request::none;
    }
    default:
      reset();
      return Request::none;
    }
  }

  void Editor::startRecording(const KeyPress& key) {
    if (replaying_ != 0) {
      return;
    }

    recording_ = true;
    recorded_.clear();
    if (count_ != 0) {
      for (const auto digit : std::to_string(count_)) {
        recorded_.push_back({KeyPress{Key::character, static_cast<char32_t>(digit)}, {}});
      }
    }

    record(key);
  }

  void Editor::record(const KeyPress& key) {
    if (recorded_.size() >= 4096) {
      recording_ = false;
      recorded_.clear();
      return;
    }

    recorded_.push_back({key, std::string{key.text}});
  }

  void Editor::finishRecording() noexcept {
    if (replaying_ == 0 && recording_) {
      recording_ = false;
      last_change_ = recorded_;
    }
  }

  void Editor::repeat() {
    const auto changes = last_change_;

    ++replaying_;
    reset();
    for (const auto& entry : changes) {
      auto key = entry.key;

      key.text = entry.text;
      press(key);
    }

    if (mode_ == Mode::insert) {
      enterNormal();
    }

    --replaying_;
  }

  std::size_t Editor::encode(char32_t value, ds::Array<char, 4>& output) noexcept {
    if (value < 0x80) {
      output.atMut(0) = static_cast<char>(value);
      return 1;
    }

    if (value < 0x800) {
      output.atMut(0) = static_cast<char>(0xc0 | (value >> 6));
      output.atMut(1) = static_cast<char>(0x80 | (value & 0x3f));
      return 2;
    }

    if (value < 0x10000) {
      output.atMut(0) = static_cast<char>(0xe0 | (value >> 12));
      output.atMut(1) = static_cast<char>(0x80 | ((value >> 6) & 0x3f));
      output.atMut(2) = static_cast<char>(0x80 | (value & 0x3f));
      return 3;
    }

    output.atMut(0) = static_cast<char>(0xf0 | (value >> 18));
    output.atMut(1) = static_cast<char>(0x80 | ((value >> 12) & 0x3f));
    output.atMut(2) = static_cast<char>(0x80 | ((value >> 6) & 0x3f));
    output.atMut(3) = static_cast<char>(0x80 | (value & 0x3f));
    return 4;
  }

}
