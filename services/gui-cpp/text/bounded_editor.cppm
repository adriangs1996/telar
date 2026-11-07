module;

#include <cstddef>
#include <cstdint>
#include <ghostty/vt/unicode.h>


#include <cstring>

export module telar.gui.text.bounded_editor;

import std;

export import telar.gui.core.unicode_scalar;

// Interface: text/grapheme_cursor.cppm
export {
namespace telar::gui {

class GraphemeCursor {
public:
  inline explicit GraphemeCursor(std::string_view text) noexcept
      : text_(text) {}

  [[nodiscard]] inline std::size_t position() const noexcept {
    return position_;
  }

  [[nodiscard]] inline std::uint8_t columns() const noexcept {
    return columns_;
  }

  [[nodiscard]] inline std::optional<std::string_view> next() {
    return advance<false>();
  }

  [[nodiscard]] inline std::optional<std::string_view> nextReplacingInvalid() noexcept {
    return advance<true>();
  }

private:
  template <bool ReplaceInvalid>
  [[nodiscard]] inline std::optional<std::string_view> advance() noexcept(ReplaceInvalid) {
    if (position_ == text_.size()) {
      return std::nullopt;
    }

    const auto first = static_cast<unsigned char>(text_[position_]);
    const auto start = position_;
    if (first >= first_printable_ascii && first < ascii_delete && (position_ + 1 == text_.size() || static_cast<unsigned char>(text_[position_ + 1]) < first_multibyte)) {
      ++position_;
      columns_ = 1;

      return std::string_view{text_.data() + start, 1};
    }

    std::array<std::uint32_t, codepoint_window> codepoints{};
    std::array<std::size_t, codepoint_window + 1> offsets{};
    std::size_t count = 0;
    auto cursor = position_;
    while (count < codepoints.size() && cursor < text_.size()) {
      const auto leading = static_cast<unsigned char>(text_[cursor]);
      const auto length = Utf8Scalar::sequenceLength(leading);
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text_.size() - cursor) {
        if constexpr (ReplaceInvalid) {
          break;
        } else {
          throw std::invalid_argument{"InvalidGraphemeUtf8"};
        }
      }

      if constexpr (ReplaceInvalid) {
        const auto decoded = Utf8Scalar::tryDecode({text_.data() + cursor, length});
        if (!decoded) {
          break;
        }

        codepoints[count] = *decoded;
      } else {
        codepoints[count] = Utf8Scalar::decode({text_.data() + cursor, length});
      }

      cursor += length;
      offsets[++count] = cursor;
    }

    if constexpr (ReplaceInvalid) {
      if (count == 0) {
        ++position_;
        columns_ = 1;

        return "�";
      }
    }

    const auto consumed = ghostty_unicode_grapheme_width(codepoints.data(), count, &columns_);
    columns_ = std::max(std::uint8_t{1}, columns_);
    position_ = offsets[consumed];
    if (codepoints.front() < first_printable_ascii || (codepoints.front() >= ascii_delete && codepoints.front() <= last_control)) {
      return " ";
    }

    return std::string_view{text_.data() + start, position_ - start};
  }

  static constexpr std::size_t codepoint_window = 16;
  static constexpr unsigned char first_printable_ascii = 0x20;
  static constexpr unsigned char ascii_delete = 0x7f;
  static constexpr unsigned char first_multibyte = 0x80;
  static constexpr std::uint32_t last_control = 0x9f;

  std::string_view text_;
  std::size_t position_ = 0;
  std::uint8_t columns_ = 0;
};

}
}

// Interface: text/cell_text_measure.cppm
export {
namespace telar::gui {

inline std::uint32_t cellTextColumns(std::string_view text) {
  GraphemeCursor cursor{text};
  std::uint32_t columns = 0;
  while (cursor.next()) {
    columns += cursor.columns();
  }

  return columns;
}

}
}

// Interface: text/editor_view.cppm
export {
namespace telar::gui {

struct EditorColumns {
  std::uint16_t first = 0;
  std::uint16_t last = 0;
};

struct EditorView {
  std::string_view text;
  std::uint16_t cursor = 0;
  std::optional<EditorColumns> selection;
  bool clipped_left = false;
  bool clipped_right = false;
};

}
}

// Interface: text/bounded_editor.cppm
export {
namespace telar::gui {

template <std::size_t Capacity>
class BoundedEditor {
public:
  static_assert(Capacity <= std::numeric_limits<std::uint16_t>::max());
  static constexpr std::size_t capacity = Capacity;

  [[nodiscard]] inline std::string_view text() const noexcept {
    return {bytes_.data(), length_};
  }

  [[nodiscard]] inline std::size_t head() const noexcept {
    return head_;
  }

  [[nodiscard]] inline std::size_t anchor() const noexcept {
    return anchor_;
  }

  [[nodiscard]] inline std::size_t scroll() const noexcept {
    return scroll_;
  }

  [[nodiscard]] inline bool hasSelection() const noexcept {
    return head_ != anchor_;
  }

  [[nodiscard]] inline std::string_view selected() const noexcept {
    return {bytes_.data() + std::min(head_, anchor_), std::max(head_, anchor_) - std::min(head_, anchor_)};
  }

  inline bool setText(std::string_view value) noexcept {
    if (value.size() > Capacity || !validUtf8(value)) {
      return false;
    }

    if (!value.empty()) {
      std::memmove(bytes_.data(), value.data(), value.size());
    }
    length_ = value.size();
    head_ = length_;
    anchor_ = length_;
    scroll_ = 0;

    return true;
  }

  inline bool selectRange(std::size_t anchor, std::size_t head) noexcept {
    if (!boundary(anchor) || !boundary(head)) {
      return false;
    }

    const auto changed = anchor_ != anchor || head_ != head;
    anchor_ = anchor;
    head_ = head;

    return changed;
  }

  inline void selectAll() noexcept {
    anchor_ = 0;
    head_ = length_;
  }

  inline void clearSelection() noexcept {
    anchor_ = head_;
  }

  inline bool replace(std::size_t first, std::size_t last, std::string_view value) noexcept {
    if (first > last || !boundary(first) || !boundary(last) || !validUtf8(value)) {
      return false;
    }

    const auto remaining = length_ - (last - first);
    if (value.size() > Capacity - remaining) {
      return false;
    }

    const auto changed = std::string_view{bytes_.data() + first, last - first} != value || head_ != first + value.size() || anchor_ != first + value.size();
    std::array<char, Capacity> copied{};
    if (!value.empty()) {
      std::memcpy(copied.data(), value.data(), value.size());
    }
    std::memmove(bytes_.data() + first + value.size(), bytes_.data() + last, length_ - last);
    if (!value.empty()) {
      std::memcpy(bytes_.data() + first, copied.data(), value.size());
    }
    length_ = remaining + value.size();
    head_ = first + value.size();
    anchor_ = head_;
    scroll_ = std::min(scroll_, head_);

    return changed;
  }

  inline void insert(std::string_view value) noexcept {
    replace(std::min(head_, anchor_), std::max(head_, anchor_), value);
  }

  inline void backspace() {
    if (deleteSelection()) {
      return;
    }

    if (const auto previous = clusterBefore(head_)) {
      remove(*previous, head_);
      head_ = *previous;
      anchor_ = head_;
    }
  }

  inline void deleteForward() {
    if (deleteSelection()) {
      return;
    }

    if (const auto next = clusterAfter(head_)) {
      remove(head_, *next);
    }
  }

  inline void moveLeft(bool extend) {
    if (!extend && hasSelection()) {
      head_ = std::min(head_, anchor_);
      anchor_ = head_;

      return;
    }

    head_ = clusterBefore(head_).value_or(head_);
    if (!extend) {
      anchor_ = head_;
    }
  }

  inline void moveRight(bool extend) {
    if (!extend && hasSelection()) {
      head_ = std::max(head_, anchor_);
      anchor_ = head_;

      return;
    }

    head_ = clusterAfter(head_).value_or(head_);
    if (!extend) {
      anchor_ = head_;
    }
  }

  inline void home(bool extend) noexcept {
    head_ = 0;
    if (!extend) {
      anchor_ = head_;
    }
  }

  inline void end(bool extend) noexcept {
    head_ = length_;
    if (!extend) {
      anchor_ = head_;
    }
  }

  inline void moveWordLeft(bool extend) noexcept {
    auto position = head_;
    while (position > 0 && isSpace(bytes_[position - 1])) {
      --position;
    }
    while (position > 0 && !isSpace(bytes_[position - 1])) {
      --position;
    }

    head_ = position;
    if (!extend) {
      anchor_ = head_;
    }
  }

  inline void moveWordRight(bool extend) noexcept {
    auto position = head_;
    while (position < length_ && isSpace(bytes_[position])) {
      ++position;
    }
    while (position < length_ && !isSpace(bytes_[position])) {
      ++position;
    }

    head_ = position;
    if (!extend) {
      anchor_ = head_;
    }
  }

  [[nodiscard]] inline EditorView view(std::uint16_t width) {
    if (width == 0) {
      return {};
    }

    if (head_ < scroll_) {
      scroll_ = startOfLine(head_, width);
    }
    while (!boundary(scroll_)) {
      --scroll_;
    }
    while (cellTextColumns(text().substr(scroll_, head_ - scroll_)) >= width) {
      const auto next = clusterAfter(scroll_);
      if (!next) {
        break;
      }

      scroll_ = std::min(*next, head_);
    }

    auto last = scroll_;
    std::uint32_t used = 0;
    while (last < length_) {
      const auto next = clusterAfter(last);
      if (!next) {
        break;
      }

      const auto columns = cellTextColumns(text().substr(last, *next - last));
      if (used + columns > width) {
        break;
      }

      used += columns;
      last = *next;
    }

    EditorView result{.text = text().substr(scroll_, last - scroll_), .cursor = columnsBetween(scroll_, head_), .selection = std::nullopt, .clipped_left = scroll_ > 0, .clipped_right = last < length_};
    if (hasSelection()) {
      const auto first_selected = std::max(std::min(head_, anchor_), scroll_);
      const auto last_selected = std::min(std::max({head_, anchor_, scroll_}), last);
      result.selection = {.first = columnsBetween(scroll_, first_selected), .last = columnsBetween(scroll_, last_selected)};
    }

    return result;
  }

private:
  static constexpr unsigned char continuation_mask = 0xc0;
  static constexpr unsigned char continuation_prefix = 0x80;

  [[nodiscard]] inline static bool validUtf8(std::string_view value) noexcept {
    std::size_t position = 0;
    while (position < value.size()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(value[position]));
      if (length == 0 || length > value.size() - position || !Utf8Scalar::tryDecode({value.data() + position, length})) {
        return false;
      }

      position += length;
    }

    return true;
  }

  [[nodiscard]] inline bool boundary(std::size_t position) const noexcept {
    return position <= length_ && (position == length_ || (static_cast<unsigned char>(bytes_[position]) & continuation_mask) != continuation_prefix);
  }

  [[nodiscard]] inline static bool isSpace(char byte) noexcept {
    return byte == ' ' || byte == '\t';
  }

  inline bool deleteSelection() noexcept {
    if (!hasSelection()) {
      return false;
    }

    const auto first = std::min(head_, anchor_);
    remove(first, std::max(head_, anchor_));
    head_ = first;
    anchor_ = first;

    return true;
  }

  inline void remove(std::size_t first, std::size_t last) noexcept {
    std::memmove(bytes_.data() + first, bytes_.data() + last, length_ - last);
    length_ -= last - first;
    if (scroll_ > length_) {
      scroll_ = 0;
    }
  }

  [[nodiscard]] inline std::optional<std::size_t> clusterBefore(std::size_t position) const {
    if (position == 0) {
      return std::nullopt;
    }

    GraphemeCursor cursor{text()};
    std::size_t previous = 0;
    while (cursor.next()) {
      if (cursor.position() >= position) {
        return previous;
      }

      previous = cursor.position();
    }

    return previous;
  }

  [[nodiscard]] inline std::optional<std::size_t> clusterAfter(std::size_t position) const {
    if (position >= length_) {
      return std::nullopt;
    }

    GraphemeCursor cursor{text().substr(position)};
    if (!cursor.next()) {
      return std::nullopt;
    }

    return position + cursor.position();
  }

  [[nodiscard]] inline std::size_t startOfLine(std::size_t position, std::uint16_t width) const {
    auto first = position;
    while (first > 0) {
      const auto previous = clusterBefore(first);
      if (!previous || cellTextColumns(text().substr(*previous, position - *previous)) > static_cast<std::uint16_t>(width - 1)) {
        break;
      }

      first = *previous;
    }

    return first;
  }

  [[nodiscard]] inline std::uint16_t columnsBetween(std::size_t first, std::size_t last) const {
    return static_cast<std::uint16_t>(cellTextColumns(text().substr(first, last - first)));
  }

  std::array<char, Capacity> bytes_{};
  std::size_t length_ = 0;
  std::size_t head_ = 0;
  std::size_t anchor_ = 0;
  std::size_t scroll_ = 0;
};

}
}

// Interface: text/caption_runs.cppm
export {
namespace telar::gui {

class CaptionRuns {
public:
  inline explicit CaptionRuns(std::string_view text) noexcept
      : cursor_(text),
        bytes_(text.size()) {}

  [[nodiscard]] inline std::optional<std::string_view> next() noexcept {
    if (cursor_.position() == bytes_) {
      return std::nullopt;
    }

    std::size_t length = 0;
    std::size_t count = 0;
    std::size_t break_length = 0;
    auto word_end = cursor_;
    while (cursor_.position() < bytes_) {
      const auto before = cursor_;
      const auto cluster = cursor_.nextReplacingInvalid();
      if (!cluster) {
        break;
      }

      const auto codepoints = static_cast<std::size_t>(std::ranges::count_if(*cluster, [](unsigned char byte) {
        return (byte & continuation_mask) != continuation_tag;
      }));
      if (length + cluster->size() > storage_.size() || count + codepoints > maximum_codepoints) {
        if (length == 0) {
          std::ranges::copy(replacement, storage_.begin());
          length = replacement.size();
        } else {
          cursor_ = before;
        }

        break;
      }

      std::ranges::copy(*cluster, storage_.begin() + static_cast<std::ptrdiff_t>(length));
      length += cluster->size();
      count += codepoints;
      if (*cluster == " ") {
        word_end = cursor_;
        break_length = length;
      }
    }

    if (cursor_.position() < bytes_ && break_length != 0) {
      cursor_ = word_end;
      length = break_length;
    }

    return std::string_view{storage_.data(), length};
  }

private:
  static constexpr std::size_t maximum_bytes = 64;
  static constexpr std::size_t maximum_codepoints = 30;
  static constexpr unsigned char continuation_mask = 0xc0;
  static constexpr unsigned char continuation_tag = 0x80;
  static constexpr std::string_view replacement = "�";

  GraphemeCursor cursor_;
  std::size_t bytes_;
  std::array<char, maximum_bytes> storage_{};
};

}
}

// Interface: text/utf16_prefix.cppm
export {
namespace telar::gui {

struct Utf16Encoding {
  std::size_t invalid_scalar_bytes = 0;
};

struct Utf16Prefix {
  static constexpr char16_t first_high_surrogate = 0xd800;
  static constexpr char16_t last_high_surrogate = 0xdbff;
  static constexpr char16_t first_low_surrogate = 0xdc00;
  static constexpr char16_t last_low_surrogate = 0xdfff;
  static constexpr std::size_t paired_units = 2;
  static constexpr std::size_t paired_bytes = 4;
  static constexpr std::size_t three_byte_scalar = 3;

  std::size_t units = 0;
  std::size_t bytes = 0;
  std::size_t requested_bytes = 0;

  [[nodiscard]] inline static Utf16Prefix fit(std::u16string_view text, std::size_t capacity, Utf16Encoding encoding = {}) noexcept {
    Utf16Prefix result;
    std::size_t position = 0;

    while (position < text.size()) {
      const auto scalar = text[position];
      const auto paired = scalar >= first_high_surrogate && scalar <= last_high_surrogate &&
                          position + 1 < text.size() &&
                          text[position + 1] >= first_low_surrogate && text[position + 1] <= last_low_surrogate;
      const auto length = paired ? paired_units : std::size_t{1};
      const auto encoded = paired ? paired_bytes : encodedBytes(scalar, encoding);

      if (result.units == position && encoded <= capacity - result.bytes) {
        result.units += length;
        result.bytes += encoded;
      }

      result.requested_bytes += encoded;
      position += length;
    }

    return result;
  }

private:
  [[nodiscard]] inline static std::size_t encodedBytes(char16_t scalar, Utf16Encoding encoding) noexcept {
    if (!Utf8Scalar::valid(scalar)) {
      return encoding.invalid_scalar_bytes;
    }

    if (scalar <= Utf8Scalar::maximum_codepoints[0]) {
      return 1;
    }

    if (scalar <= Utf8Scalar::maximum_codepoints[1]) {
      return 2;
    }

    return three_byte_scalar;
  }
};

}
}

// Interface: text/wrapped_lines.cppm
export {
namespace telar::gui {

class WrappedLines {
public:
  inline explicit WrappedLines(std::string_view text, std::uint16_t columns, bool words = false) noexcept
      : text_(text),
        columns_(columns),
        words_(words) {}

  [[nodiscard]] inline std::optional<std::string_view> next() noexcept {
    if (finished_ || columns_ == 0) {
      return std::nullopt;
    }

    const auto start = position_;
    auto word_start = start;
    std::uint32_t used = 0;
    auto remaining = text_;
    remaining.remove_prefix(start);
    GraphemeCursor cursor{remaining};
    while (start + cursor.position() < text_.size()) {
      const auto before = start + cursor.position();
      if (text_[before] == '\n' || text_[before] == '\r') {
        position_ = before + 1;
        if (text_[before] == '\r' && position_ < text_.size() && text_[position_] == '\n') {
          ++position_;
        }

        remaining.remove_suffix(text_.size() - before);

        return remaining;
      }

      const auto cluster = cursor.nextReplacingInvalid();
      if (used + cursor.columns() > columns_) {
        position_ = before;
        if (used == 0) {
          position_ = start + cursor.position();
        } else if (words_ && word_start > start) {
          position_ = word_start;
        }

        finished_ = position_ == text_.size();

        remaining.remove_suffix(text_.size() - position_);

        return remaining;
      }

      used += cursor.columns();
      if (words_ && cluster == " ") {
        word_start = start + cursor.position();
      }
    }

    position_ = text_.size();
    finished_ = true;

    return remaining;
  }

private:
  std::string_view text_;
  std::size_t position_ = 0;
  std::uint16_t columns_;
  bool words_;
  bool finished_ = false;
};

}
}
