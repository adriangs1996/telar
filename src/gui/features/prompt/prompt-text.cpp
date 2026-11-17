module telar.gui.features.prompt;

import std;

namespace telar::gui::features::prompt {

  std::string_view Text::view() const noexcept {
    return bytes_;
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

    const auto kind = !typing ? Group::none : text.empty() ? Group::erase
                                                           : Group::insert;
    const bool joined = kind != Group::none && kind == group_ && !undo_.empty() && (kind == Group::insert ? start == cursor_ : end == cursor_ || start == cursor_);
    if (!joined) {
      record();
    }

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
    return swap(undo_, redo_);
  }

  bool Text::redo() {
    return swap(redo_, undo_);
  }

  void Text::seal() noexcept {
    group_ = Group::none;
  }

  std::size_t Text::next(std::size_t offset) const noexcept {
    if (offset >= bytes_.size()) {
      return bytes_.size();
    }

    ++offset;
    while (offset < bytes_.size() && continuation(bytes_[offset])) {
      ++offset;
    }

    return offset;
  }

  std::size_t Text::previous(std::size_t offset) const noexcept {
    if (offset == 0) {
      return 0;
    }

    --offset;
    while (offset > 0 && continuation(bytes_[offset])) {
      --offset;
    }

    return offset;
  }

  std::size_t Text::lineStart(std::size_t offset) const noexcept {
    const auto found = bytes_.rfind('\n', offset == 0 ? std::string::npos : offset - 1);

    return offset == 0 || found == std::string::npos ? 0 : found + 1;
  }

  std::size_t Text::lineEnd(std::size_t offset) const noexcept {
    const auto found = bytes_.find('\n', offset);

    return found == std::string::npos ? bytes_.size() : found;
  }

  std::size_t Text::lineCount() const noexcept {
    return static_cast<std::size_t>(std::ranges::count(bytes_, '\n')) + 1;
  }

  std::size_t Text::lineOf(std::size_t offset) const noexcept {
    return static_cast<std::size_t>(std::count(bytes_.begin(), bytes_.begin() + static_cast<std::ptrdiff_t>(std::min(offset, bytes_.size())), '\n'));
  }

  std::size_t Text::column(std::size_t offset) const noexcept {
    std::size_t count = 0;

    for (auto position = lineStart(offset); position < offset; position = next(position)) {
      ++count;
    }

    return count;
  }

  std::size_t Text::atColumn(std::size_t line_start, std::size_t column) const noexcept {
    const auto end = lineEnd(line_start);
    auto position = line_start;

    for (std::size_t count = 0; count < column && position < end; ++count) {
      position = next(position);
    }

    return position;
  }

  bool Text::continuation(char byte) noexcept {
    return (static_cast<unsigned char>(byte) & 0xc0) == 0x80;
  }

  std::size_t Text::boundary(std::size_t offset) const noexcept {
    while (offset > 0 && offset < bytes_.size() && continuation(bytes_[offset])) {
      --offset;
    }

    return offset;
  }

  void Text::record() {
    if (undo_.size() == undo_capacity) {
      undo_.erase(undo_.begin());
    }

    undo_.push_back({bytes_, cursor_});
  }

  bool Text::swap(std::vector<Snapshot>& from, std::vector<Snapshot>& to) {
    if (from.empty()) {
      return false;
    }

    to.push_back({bytes_, cursor_});
    bytes_ = std::move(from.back().bytes);
    cursor_ = anchor_ = std::min(from.back().cursor, bytes_.size());
    from.pop_back();
    group_ = Group::none;
    ++revision_;
    return true;
  }

  CharacterClass classify(char byte) noexcept {
    const auto value = static_cast<unsigned char>(byte);
    if (value == ' ' || value == '\t' || value == '\n') {
      return CharacterClass::blank;
    }

    if (value >= 0x80 || value == '_' || (value >= '0' && value <= '9') || ((value | 0x20) >= 'a' && (value | 0x20) <= 'z')) {
      return CharacterClass::word;
    }

    return CharacterClass::punctuation;
  }

}
