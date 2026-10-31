#pragma once

#include "grapheme_cursor.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

class CaptionRuns {
public:
  explicit CaptionRuns(std::string_view text) noexcept
      : cursor_(text),
        bytes_(text.size()) {}

  [[nodiscard]] std::optional<std::string_view> next() noexcept {
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
