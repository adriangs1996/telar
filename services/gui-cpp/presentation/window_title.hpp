#pragma once

#include "core/unicode_scalar.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class WindowTitle {
public:
  static constexpr std::size_t capacity = 256;
  static constexpr std::string_view default_title = "Telar";

  struct Tokens {
    std::string_view workspace;
    std::string_view tab;
    std::string_view pane_title;
    std::string_view hostname;
  };

  [[nodiscard]] static WindowTitle render(std::string_view pattern, Tokens tokens) {
    WindowTitle result;
    while (!pattern.empty()) {
      const auto consumed = result.expand(pattern, tokens);
      if (consumed != 0) {
        pattern.remove_prefix(consumed);
      } else {
        result.append(pattern.substr(0, 1));
        pattern.remove_prefix(1);
      }
    }

    result.filter();

    return result;
  }

  void appendSuffix(std::string_view suffix) noexcept {
    constexpr unsigned continuation_mask = 0xc0;
    const auto suffix_length = std::min(suffix.size(), capacity);
    auto kept = std::min(length_, capacity - suffix_length);
    while (kept > 0 && kept < length_ && (static_cast<unsigned char>(bytes_[kept]) & continuation_mask) == Utf8Scalar::continuation_prefix) {
      --kept;
    }

    if (suffix_length != 0) {
      std::memmove(bytes_.data() + kept, suffix.data(), suffix_length);
    }

    length_ = kept + suffix_length;
  }

  [[nodiscard]] std::string_view view() const noexcept {
    return {bytes_.data(), length_};
  }

private:
  std::size_t expand(std::string_view pattern, Tokens values) {
    if (!pattern.starts_with('{')) {
      return 0;
    }

    const auto close = pattern.find('}');
    if (close == std::string_view::npos) {
      return 0;
    }

    const auto value = token(pattern.substr(1, close - 1), values);
    if (!value) {
      return 0;
    }

    append(*value);

    return close + 1;
  }

  static std::optional<std::string_view> token(std::string_view name, Tokens values) noexcept {
    if (name == "workspace") {
      return values.workspace;
    }

    if (name == "tab") {
      return values.tab;
    }

    if (name == "pane_title") {
      return values.pane_title;
    }

    if (name == "hostname") {
      return values.hostname;
    }

    return std::nullopt;
  }

  void append(std::string_view value) noexcept {
    const auto count = std::min(capacity - length_, value.size());
    if (count != 0) {
      std::memcpy(bytes_.data() + length_, value.data(), count);
      length_ += count;
    }
  }

  void filter() {
    constexpr unsigned printable_start = 0x20;
    constexpr unsigned control_start = 0x7f;
    constexpr unsigned control_end = 0x9f;
    std::size_t position = 0;
    std::size_t written = 0;
    while (position < length_) {
      const auto first = static_cast<unsigned char>(bytes_[position]);
      const auto size = first <= Utf8Scalar::maximum_codepoints.front() ? std::size_t{1} : static_cast<std::size_t>(std::countl_one(first));
      if (size > Utf8Scalar::leading_masks.size() || size > length_ - position) {
        break;
      }

      try {
        const auto codepoint = Utf8Scalar::decode({bytes_.data() + position, size});
        if (codepoint >= printable_start && (codepoint < control_start || codepoint > control_end)) {
          std::memmove(bytes_.data() + written, bytes_.data() + position, size);
          written += size;
        }
      } catch (const std::invalid_argument &) {
        break;
      }

      position += size;
    }

    length_ = written;
  }

  std::array<char, capacity> bytes_{};
  std::size_t length_ = 0;
};

}
