module telar.gui.features.prompt;

import std;
import telar.gui.foundation.text;

import telar.tbc;

namespace telar::gui::features::prompt {

  Text::Text(tbc::mut_a<Memory> memory)
      : bytes_(memory),
        undo_(memory),
        redo_(memory) {}

  std::string_view Text::view() const noexcept {
    return bytes_.view();
  }

  std::size_t Text::size() const noexcept {
    return bytes_.size();
  }

  bool Text::empty() const noexcept {
    return bytes_.empty();
  }

  std::size_t Text::cursor() const noexcept {
    return cursor_;
  }

  std::size_t Text::anchor() const noexcept {
    return anchor_;
  }

  bool Text::selecting() const noexcept {
    return anchor_ != cursor_;
  }

  std::size_t Text::selectionStart() const noexcept {
    return std::min(anchor_, cursor_);
  }

  std::size_t Text::selectionEnd() const noexcept {
    return std::max(anchor_, cursor_);
  }

  std::uint64_t Text::revision() const noexcept {
    return revision_;
  }

  void Text::moveTo(std::size_t offset, bool extend) noexcept {
    cursor_ = boundary(std::min(offset, bytes_.size()));
    if (!extend) {
      anchor_ = cursor_;
    }

    group_ = Group::none;
  }

  void Text::select(std::size_t anchor, std::size_t cursor) noexcept {
    anchor_ = boundary(std::min(anchor, bytes_.size()));
    cursor_ = boundary(std::min(cursor, bytes_.size()));
    group_ = Group::none;
  }

  bool Text::replace(std::size_t start, std::size_t end, std::string_view text, bool typing) {
    start = boundary(std::min(start, bytes_.size()));
    end = boundary(std::clamp(end, start, bytes_.size()));
    if (bytes_.size() - (end - start) + text.size() > capacity) {
      return false;
    }

    auto kind = Group::none;

    if (typing) {
      kind = text.empty() ? Group::erase : Group::insert;
    }

    const bool joined = kind != Group::none && kind == group_ && !undo_.empty() && (kind == Group::insert ? start == cursor_ : end == cursor_ || start == cursor_);
    const bool open = holding_ ? !held_ : !joined;

    track(start, end, text.size(), open);
    held_ = held_ || holding_;

    bytes_.replace(start, end - start, text);
    cursor_ = anchor_ = start + text.size();
    group_ = kind;
    redo_.clear();
    ++revision_;
    return true;
  }

  bool Text::insert(std::string_view text, bool typing) {
    return replace(selectionStart(), selectionEnd(), text, typing);
  }

  void Text::assign(std::string_view text) {
    replace(0, bytes_.size(), text.substr(0, capacity));
  }

  void Text::clear() noexcept {
    bytes_.clear();
    cursor_ = anchor_ = 0;
    undo_.clear();
    redo_.clear();
    group_ = Group::none;
    ++revision_;
  }

  bool Text::undo() {
    return travel(true);
  }

  bool Text::redo() {
    return travel(false);
  }

  void Text::hold() noexcept {
    holding_ = true;
    held_ = false;
  }

  void Text::release() noexcept {
    holding_ = false;
    held_ = false;
    group_ = Group::none;
  }

  void Text::seal() noexcept {
    group_ = Group::none;
  }

  std::size_t Text::next(std::size_t offset) const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    if (offset >= bytes_.size()) {
      return bytes_.size();
    }

    GraphemeCursor graphemes{view().substr(offset)};

    static_cast<void>(graphemes.nextReplacingInvalid());
    return offset + std::max<std::size_t>(graphemes.position(), 1);
  }

  std::size_t Text::previous(std::size_t offset) const noexcept { // NOLINT(bugprone-exception-escape): substr is given offsets within the text, which cannot throw
    // Graphemes are read from a code point a bounded way back, which holds any cluster a line
    // shows, or from the line's start.
    constexpr std::size_t lookback = 256;

    if (offset == 0) {
      return 0;
    }

    auto from = std::max(lineStart(offset - 1), offset > lookback ? offset - lookback : 0);

    while (from > 0 && continuation(bytes_[from])) {
      --from;
    }

    GraphemeCursor graphemes{view().substr(from, offset - from)};
    auto boundary = from;

    while (graphemes.nextReplacingInvalid()) {
      if (from + graphemes.position() >= offset) {
        break;
      }

      boundary = from + graphemes.position();
    }

    return boundary;
  }

  std::size_t Text::lineStart(std::size_t offset) const noexcept {
    const auto found = view().rfind('\n', offset == 0 ? std::string_view::npos : offset - 1);

    return offset == 0 || found == std::string_view::npos ? 0 : found + 1;
  }

  std::size_t Text::lineEnd(std::size_t offset) const noexcept {
    const auto found = view().find('\n', offset);

    return found == std::string_view::npos ? bytes_.size() : found;
  }

  std::size_t Text::lineCount() const noexcept {
    return static_cast<std::size_t>(std::ranges::count(view(), '\n')) + 1;
  }

  std::size_t Text::lineOf(std::size_t offset) const noexcept {
    const std::string_view before{view().data(), std::min(offset, size())};

    return static_cast<std::size_t>(std::ranges::count(before, '\n'));
  }

  std::size_t Text::column(std::size_t offset) const noexcept {
    std::size_t count = 0;

    for (auto position = lineStart(offset); position < offset; position = next(position)) {
      ++count;
    }

    return count;
  }

  std::size_t Text::atColumn(LineColumn place) const noexcept {
    const auto end = lineEnd(place.line_start);
    auto position = place.line_start;

    for (std::size_t count = 0; count < place.column && position < end; ++count) {
      position = next(position);
    }

    return position;
  }

  bool Text::continuation(char byte) noexcept {
    // A UTF-8 continuation byte is 10xxxxxx.
    constexpr unsigned continuation_mask = 0xc0U;
    constexpr unsigned continuation_bits = 0x80U;

    return (static_cast<unsigned char>(byte) & continuation_mask) == continuation_bits;
  }

  std::size_t Text::boundary(std::size_t offset) const noexcept {
    while (offset > 0 && offset < bytes_.size() && continuation(bytes_[offset])) {
      --offset;
    }

    return offset;
  }

  void Text::track(std::size_t start, std::size_t end, std::size_t inserted, bool open) {
    const auto view = bytes_.view();
    auto& memory = bytes_.memory();

    if (open || undo_.empty()) {
      if (undo_.size() == undo_capacity) {
        static_cast<void>(undo_.remove(0));
      }

      undo_.push(Snapshot{.start = start, .end = start + inserted, .removed = ds::String<Memory>{memory, view.substr(start, end - start)}, .cursor = cursor_});
      return;
    }

    // The step's range grows over the change: what it takes beyond the range is still the text
    // the step began from.
    auto& step = undo_.backMut();
    const auto from = std::min(step.start, start);
    const auto until = std::max(step.end, end);
    ds::String<Memory> removed{memory};

    removed.reserve((step.start - from) + step.removed.size() + (until - step.end));
    removed.append(view.substr(from, step.start - from));
    removed.append(step.removed);
    removed.append(view.substr(step.end, until - step.end));
    step.removed = std::move(removed);
    step.start = from;
    step.end = until - (end - start) + inserted;
  }

  bool Text::travel(bool back) {
    auto& source = back ? undo_ : redo_;
    auto& target = back ? redo_ : undo_;

    if (source.empty()) {
      return false;
    }

    const auto step = source.remove(source.size() - 1);
    Snapshot inverse{.start = step.start, .end = step.start + step.removed.size(), .removed = ds::String<Memory>{bytes_.memory(), bytes_.view().substr(step.start, step.end - step.start)}, .cursor = cursor_};

    bytes_.replace(step.start, step.end - step.start, step.removed);
    target.push(std::move(inverse));
    cursor_ = anchor_ = std::min(step.cursor, bytes_.size());
    group_ = Group::none;
    holding_ = false;
    held_ = false;
    ++revision_;
    return true;
  }

  CharacterClass classify(char byte) noexcept {
    const auto value = static_cast<unsigned char>(byte);
    if (value == ' ' || value == '\t' || value == '\n') {
      return CharacterClass::blank;
    }

    // Every byte past ASCII counts as a word character; setting bit 5 folds an ASCII letter to lowercase.
    constexpr unsigned char first_non_ascii = 0x80;
    constexpr unsigned lowercase_bit = 0x20U;

    if (value >= first_non_ascii || value == '_' || (value >= '0' && value <= '9') || ((value | lowercase_bit) >= 'a' && (value | lowercase_bit) <= 'z')) {
      return CharacterClass::word;
    }

    return CharacterClass::punctuation;
  }

}
