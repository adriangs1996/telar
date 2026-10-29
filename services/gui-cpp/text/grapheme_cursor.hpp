#pragma once

#include "core/unicode_scalar.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <ghostty/vt/unicode.h>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class GraphemeCursor {
public:
  explicit GraphemeCursor(std::string_view text) noexcept
      : text_(text) {}

  [[nodiscard]] std::size_t position() const noexcept {
    return position_;
  }

  [[nodiscard]] std::uint8_t columns() const noexcept {
    return columns_;
  }

  [[nodiscard]] std::optional<std::string_view> next() {
    return advance<false>();
  }

  [[nodiscard]] std::optional<std::string_view> nextReplacingInvalid() noexcept {
    return advance<true>();
  }

private:
  template <bool ReplaceInvalid>
  [[nodiscard]] std::optional<std::string_view> advance() noexcept(ReplaceInvalid) {
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
