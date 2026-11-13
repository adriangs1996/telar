module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.text;

import std;

// The text of the command being edited: UTF-8 bytes, a cursor and an anchor that are always on
// code point boundaries, and grouped undo. Every edit goes through `replace`, so undo, the
// revision and the bounds hold for all of them.
export namespace telar::gui::prompt {

class Text {
public:
  // A pasted file must not grow the editor without bound; the shell's own line editor has
  // limits of the same order.
  static constexpr std::size_t capacity = 256 * 1024;
  static constexpr std::size_t undo_capacity = 256;

  inline std::string_view view() const noexcept {
    return bytes_;
  }

  inline std::size_t size() const noexcept {
    return bytes_.size();
  }

  inline bool empty() const noexcept {
    return bytes_.empty();
  }

  inline std::size_t cursor() const noexcept {
    return cursor_;
  }

  // The other end of the selection; equal to the cursor without one.
  inline std::size_t anchor() const noexcept {
    return anchor_;
  }

  inline bool selecting() const noexcept {
    return anchor_ != cursor_;
  }

  inline std::size_t selectionStart() const noexcept {
    return std::min(anchor_, cursor_);
  }

  inline std::size_t selectionEnd() const noexcept {
    return std::max(anchor_, cursor_);
  }

  // Counts every change to the text, so views redraw only what changed.
  inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  inline void moveTo(std::size_t offset, bool extend = false) noexcept {
    cursor_ = boundary(std::min(offset, bytes_.size()));
    if (!extend) {
      anchor_ = cursor_;
    }
    group_ = Group::none;
  }

  inline void select(std::size_t anchor, std::size_t cursor) noexcept {
    anchor_ = boundary(std::min(anchor, bytes_.size()));
    cursor_ = boundary(std::min(cursor, bytes_.size()));
    group_ = Group::none;
  }

  // Replaces [start, end) with `text` and leaves the cursor after it. Consecutive typing or
  // deleting joins one undo step, so undo removes a word typed, not a letter. Returns false
  // when the result would exceed the capacity, leaving everything as it was.
  inline bool replace(std::size_t start, std::size_t end, std::string_view text, bool typing = false) {
    start = boundary(std::min(start, bytes_.size()));
    end = boundary(std::clamp(end, start, bytes_.size()));
    if (bytes_.size() - (end - start) + text.size() > capacity) {
      return false;
    }

    const auto kind = !typing ? Group::none : text.empty() ? Group::erase : Group::insert;
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

  inline bool insert(std::string_view text, bool typing = false) {
    return replace(selectionStart(), selectionEnd(), text, typing);
  }

  inline void assign(std::string_view text) {
    replace(0, bytes_.size(), text.substr(0, capacity));
  }

  inline void clear() noexcept {
    bytes_.clear();
    cursor_ = anchor_ = 0;
    undo_.clear();
    redo_.clear();
    group_ = Group::none;
    ++revision_;
  }

  inline bool undo() {
    return swap(undo_, redo_);
  }

  inline bool redo() {
    return swap(redo_, undo_);
  }

  // Ends the current undo group, as moving the cursor does.
  inline void seal() noexcept {
    group_ = Group::none;
  }

  // Code point navigation.
  inline std::size_t next(std::size_t offset) const noexcept {
    if (offset >= bytes_.size()) {
      return bytes_.size();
    }
    ++offset;
    while (offset < bytes_.size() && continuation(bytes_[offset])) {
      ++offset;
    }
    return offset;
  }

  inline std::size_t previous(std::size_t offset) const noexcept {
    if (offset == 0) {
      return 0;
    }
    --offset;
    while (offset > 0 && continuation(bytes_[offset])) {
      --offset;
    }
    return offset;
  }

  inline std::size_t lineStart(std::size_t offset) const noexcept {
    const auto found = bytes_.rfind('\n', offset == 0 ? std::string::npos : offset - 1);
    return offset == 0 || found == std::string::npos ? 0 : found + 1;
  }

  inline std::size_t lineEnd(std::size_t offset) const noexcept {
    const auto found = bytes_.find('\n', offset);
    return found == std::string::npos ? bytes_.size() : found;
  }

  inline std::size_t lineCount() const noexcept {
    return static_cast<std::size_t>(std::ranges::count(bytes_, '\n')) + 1;
  }

  inline std::size_t lineOf(std::size_t offset) const noexcept {
    return static_cast<std::size_t>(std::count(bytes_.begin(), bytes_.begin() + static_cast<std::ptrdiff_t>(std::min(offset, bytes_.size())), '\n'));
  }

  // The code points between the line start and the offset, for keeping a column across lines.
  inline std::size_t column(std::size_t offset) const noexcept {
    std::size_t count = 0;
    for (auto position = lineStart(offset); position < offset; position = next(position)) {
      ++count;
    }
    return count;
  }

  inline std::size_t atColumn(std::size_t line_start, std::size_t column) const noexcept {
    const auto end = lineEnd(line_start);
    auto position = line_start;
    for (std::size_t count = 0; count < column && position < end; ++count) {
      position = next(position);
    }
    return position;
  }

  inline static bool continuation(char byte) noexcept {
    return (static_cast<unsigned char>(byte) & 0xc0) == 0x80;
  }

private:
  enum class Group : std::uint8_t {
    none,
    insert,
    erase,
  };

  struct Snapshot {
    std::string bytes;
    std::size_t cursor;
  };

  inline std::size_t boundary(std::size_t offset) const noexcept {
    while (offset > 0 && offset < bytes_.size() && continuation(bytes_[offset])) {
      --offset;
    }
    return offset;
  }

  inline void record() {
    if (undo_.size() == undo_capacity) {
      undo_.erase(undo_.begin());
    }
    undo_.push_back({bytes_, cursor_});
  }

  inline bool swap(std::vector<Snapshot> &from, std::vector<Snapshot> &to) {
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

  std::string bytes_;
  std::vector<Snapshot> undo_;
  std::vector<Snapshot> redo_;
  std::size_t cursor_ = 0;
  std::size_t anchor_ = 0;
  std::uint64_t revision_ = 0;
  Group group_ = Group::none;
};

// Word classes as vim and readline use them: letters, digits and underscore form words,
// other non-blank characters form their own, and blanks separate both.
enum class CharacterClass : std::uint8_t {
  blank,
  word,
  punctuation,
};

inline CharacterClass classify(char byte) noexcept {
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
