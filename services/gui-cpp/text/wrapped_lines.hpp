#pragma once

#include "grapheme_cursor.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

class WrappedLines {
public:
  explicit WrappedLines(std::string_view text, std::uint16_t columns, bool words = false) noexcept
      : text_(text),
        columns_(columns),
        words_(words) {}

  [[nodiscard]] std::optional<std::string_view> next() noexcept {
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
