#pragma once

#include "core/unicode_scalar.hpp"
#include "text/bounded_text.hpp"
#include "text/grapheme_cursor.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct HistoryPath {
  static constexpr std::size_t byte_capacity = 61;
  static constexpr std::size_t plain_codepoints = 30;
  static constexpr std::size_t tail_codepoints = 28;
  static constexpr std::string_view prefix = "…/";
  using Text = BoundedText<byte_capacity>;

  [[nodiscard]] static Text compact(std::string_view path) {
    if (path.size() <= byte_capacity && tailStart(path, {.bytes = byte_capacity, .codepoints = plain_codepoints}) == 0) {
      return copy(path);
    }

    const auto last = path.find_last_not_of('/');
    if (last == std::string_view::npos) {
      return copy("/");
    }

    const auto end = last + 1;
    const auto leaf_separator = path.substr(0, end).find_last_of('/');
    const auto leaf = leaf_separator == std::string_view::npos ? 0 : leaf_separator + 1;
    const auto parent_separator = path.substr(0, leaf == 0 ? 0 : leaf - 1).find_last_of('/');
    const auto parent = parent_separator == std::string_view::npos ? 0 : parent_separator + 1;
    const auto candidate = path.substr(parent, end - parent);
    auto start = tailStart(candidate, {.bytes = byte_capacity - prefix.size(), .codepoints = tail_codepoints});
    if (start != 0) {
      const auto separator = candidate.find('/', start);
      if (separator != std::string_view::npos) {
        start = separator + 1;
      }
    }

    Text result;
    result.append(prefix);
    append(result, candidate.substr(start));

    return result;
  }

private:
  struct Limits {
    std::size_t bytes;
    std::size_t codepoints;
  };

  [[nodiscard]] static std::size_t codepoints(std::string_view cluster) noexcept {
    std::size_t count = 0;
    for (const auto byte : cluster) {
      const auto value = static_cast<unsigned char>(byte);
      if ((value & utf8_prefix_mask) != Utf8Scalar::continuation_prefix) {
        ++count;
      }
    }

    return count;
  }

  [[nodiscard]] static std::size_t tailStart(std::string_view text, Limits limits) noexcept {
    GraphemeCursor right{text};
    auto left = right;
    std::size_t bytes = 0;
    std::size_t scalars = 0;
    while (const auto cluster = right.nextReplacingInvalid()) {
      bytes += cluster->size();
      scalars += codepoints(*cluster);
      while (bytes > limits.bytes || scalars > limits.codepoints) {
        const auto first = left.nextReplacingInvalid();
        if (!first) {
          return text.size();
        }

        bytes -= first->size();
        scalars -= codepoints(*first);
      }
    }

    return left.position();
  }

  static void append(Text &destination, std::string_view path) {
    GraphemeCursor cursor{path};
    while (const auto cluster = cursor.nextReplacingInvalid()) {
      destination.append(*cluster);
    }
  }

  [[nodiscard]] static Text copy(std::string_view path) {
    Text result;
    append(result, path);

    return result;
  }

  static constexpr unsigned utf8_prefix_mask = 0xc0;
};

}
