#pragma once

#include "cell_text_measure.hpp"
#include "core/unicode_scalar.hpp"
#include "editor_view.hpp"
#include "grapheme_cursor.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::gui {

template <std::size_t Capacity>
class BoundedEditor {
public:
  static_assert(Capacity <= std::numeric_limits<std::uint16_t>::max());
  static constexpr std::size_t capacity = Capacity;

  [[nodiscard]] std::string_view text() const noexcept {
    return {bytes_.data(), length_};
  }

  [[nodiscard]] std::size_t head() const noexcept {
    return head_;
  }

  [[nodiscard]] std::size_t anchor() const noexcept {
    return anchor_;
  }

  [[nodiscard]] std::size_t scroll() const noexcept {
    return scroll_;
  }

  [[nodiscard]] bool hasSelection() const noexcept {
    return head_ != anchor_;
  }

  [[nodiscard]] std::string_view selected() const noexcept {
    return {bytes_.data() + std::min(head_, anchor_), std::max(head_, anchor_) - std::min(head_, anchor_)};
  }

  bool setText(std::string_view value) noexcept {
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

  bool selectRange(std::size_t anchor, std::size_t head) noexcept {
    if (!boundary(anchor) || !boundary(head)) {
      return false;
    }

    const auto changed = anchor_ != anchor || head_ != head;
    anchor_ = anchor;
    head_ = head;

    return changed;
  }

  void selectAll() noexcept {
    anchor_ = 0;
    head_ = length_;
  }

  void clearSelection() noexcept {
    anchor_ = head_;
  }

  bool replace(std::size_t first, std::size_t last, std::string_view value) noexcept {
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

  void insert(std::string_view value) noexcept {
    replace(std::min(head_, anchor_), std::max(head_, anchor_), value);
  }

  void backspace() {
    if (deleteSelection()) {
      return;
    }

    if (const auto previous = clusterBefore(head_)) {
      remove(*previous, head_);
      head_ = *previous;
      anchor_ = head_;
    }
  }

  void deleteForward() {
    if (deleteSelection()) {
      return;
    }

    if (const auto next = clusterAfter(head_)) {
      remove(head_, *next);
    }
  }

  void moveLeft(bool extend) {
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

  void moveRight(bool extend) {
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

  void home(bool extend) noexcept {
    head_ = 0;
    if (!extend) {
      anchor_ = head_;
    }
  }

  void end(bool extend) noexcept {
    head_ = length_;
    if (!extend) {
      anchor_ = head_;
    }
  }

  void moveWordLeft(bool extend) noexcept {
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

  void moveWordRight(bool extend) noexcept {
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

  [[nodiscard]] EditorView view(std::uint16_t width) {
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

  [[nodiscard]] static bool validUtf8(std::string_view value) noexcept {
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

  [[nodiscard]] bool boundary(std::size_t position) const noexcept {
    return position <= length_ && (position == length_ || (static_cast<unsigned char>(bytes_[position]) & continuation_mask) != continuation_prefix);
  }

  [[nodiscard]] static bool isSpace(char byte) noexcept {
    return byte == ' ' || byte == '\t';
  }

  bool deleteSelection() noexcept {
    if (!hasSelection()) {
      return false;
    }

    const auto first = std::min(head_, anchor_);
    remove(first, std::max(head_, anchor_));
    head_ = first;
    anchor_ = first;

    return true;
  }

  void remove(std::size_t first, std::size_t last) noexcept {
    std::memmove(bytes_.data() + first, bytes_.data() + last, length_ - last);
    length_ -= last - first;
    if (scroll_ > length_) {
      scroll_ = 0;
    }
  }

  [[nodiscard]] std::optional<std::size_t> clusterBefore(std::size_t position) const {
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

  [[nodiscard]] std::optional<std::size_t> clusterAfter(std::size_t position) const {
    if (position >= length_) {
      return std::nullopt;
    }

    GraphemeCursor cursor{text().substr(position)};
    if (!cursor.next()) {
      return std::nullopt;
    }

    return position + cursor.position();
  }

  [[nodiscard]] std::size_t startOfLine(std::size_t position, std::uint16_t width) const {
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

  [[nodiscard]] std::uint16_t columnsBetween(std::size_t first, std::size_t last) const {
    return static_cast<std::uint16_t>(cellTextColumns(text().substr(first, last - first)));
  }

  std::array<char, Capacity> bytes_{};
  std::size_t length_ = 0;
  std::size_t head_ = 0;
  std::size_t anchor_ = 0;
  std::size_t scroll_ = 0;
};

}
