#pragma once

#include "link_text.hpp"
#include <algorithm>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct PathLocation {
  std::string_view path;
  std::uint32_t line = 0;
  std::uint32_t column = 0;
};

class PathRecognizer {
public:
  [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size() || !tokenByte(line[byte_offset])) {
      return {};
    }

    auto start = byte_offset;
    while (start > 0 && tokenByte(line[start - 1])) {
      --start;
    }

    auto end = byte_offset + 1;
    while (end < line.size() && tokenByte(line[end])) {
      ++end;
    }

    if (end - start > LinkText::maximum_uri_bytes) {
      return {};
    }

    auto segment = start;
    while (segment < end) {
      const auto separator = std::min(line.substr(0, end).find(':', segment), end);
      const auto suffix_end = positionEnd(line.substr(0, end), separator);
      const auto first = segment + trimLeading(line.substr(segment, separator - segment));
      const auto last = suffix_end == separator ? first + trimTrailing(line.substr(first, separator - first)) : separator;
      const auto match_end = suffix_end == separator ? last : suffix_end;
      if (looksLikePath(line.substr(first, last - first), suffix_end != separator) && byte_offset >= first && byte_offset < match_end) {
        return LinkTextMatch{.scheme = LinkScheme::path, .extent = {.start = first, .end = match_end}, .destination = {.start = first, .end = match_end}};
      }

      segment = std::max(separator, suffix_end) + 1;
    }

    return {};
  }

  [[nodiscard]] static PathLocation locate(std::string_view text) {
    const auto separator = text.find(':');
    if (separator == std::string_view::npos) {
      return {.path = text};
    }

    PathLocation result{.path = text.substr(0, separator)};
    const auto line_digits = numberLength(text.substr(separator + 1));
    result.line = number(text.substr(separator + 1, line_digits));
    const auto column_start = separator + 1 + line_digits;
    if (line_digits != 0 && column_start < text.size() && text[column_start] == ':') {
      const auto column_digits = numberLength(text.substr(column_start + 1));
      result.column = number(text.substr(column_start + 1, column_digits));
    }

    return result;
  }

  [[nodiscard]] static std::optional<PathLocation> fragment(std::string_view text) {
    if (text.starts_with('L') || text.starts_with('l')) {
      text.remove_prefix(1);
    }

    const auto line_digits = numberLength(text);
    if (line_digits == 0) {
      return {};
    }

    PathLocation result{.path = {}, .line = number(text.substr(0, line_digits))};
    text.remove_prefix(line_digits);
    if (text.starts_with(':') || text.starts_with('C') || text.starts_with('c')) {
      const auto column_digits = numberLength(text.substr(1));
      if (column_digits == 0) {
        return {};
      }

      result.column = number(text.substr(1, column_digits));
      text.remove_prefix(1 + column_digits);
    }

    return text.empty() || text.starts_with('-') ? std::optional{result} : std::nullopt;
  }

private:
  static constexpr std::size_t maximum_number_digits = 9;

  [[nodiscard]] static std::size_t numberLength(std::string_view text) noexcept {
    const auto *const end = std::ranges::find_if_not(text, LinkText::digit);
    const auto length = static_cast<std::size_t>(end - text.begin());

    return length > maximum_number_digits ? 0 : length;
  }

  [[nodiscard]] static std::uint32_t number(std::string_view text) noexcept {
    std::uint32_t result = 0;
    static_cast<void>(std::from_chars(text.data(), text.data() + text.size(), result));

    return result;
  }

  [[nodiscard]] static std::size_t positionEnd(std::string_view token, std::size_t colon) {
    if (colon >= token.size()) {
      return colon;
    }

    const auto line_digits = numberLength(token.substr(colon + 1));
    if (line_digits == 0) {
      return colon;
    }

    const auto line_end = colon + 1 + line_digits;
    if (line_end >= token.size() || token[line_end] != ':') {
      return line_end;
    }

    const auto column_digits = numberLength(token.substr(line_end + 1));

    return column_digits == 0 ? line_end : line_end + 1 + column_digits;
  }

  [[nodiscard]] static bool looksLikePath(std::string_view text, bool positioned) {
    if (text.size() < 2 || text.front() == '-' || text.front() == '+' || text.starts_with("//") || !std::ranges::any_of(text, LinkText::alphanumeric)) {
      return false;
    }

    if (text.starts_with('/') || text.starts_with("~/") || text.starts_with("./") || text.starts_with("../")) {
      return true;
    }

    const auto slash = text.rfind('/');
    if (slash == std::string_view::npos && !positioned) {
      return false;
    }

    const auto name = text.substr(slash == std::string_view::npos ? 0 : slash + 1);
    const auto dot = name.rfind('.');

    return dot != std::string_view::npos && dot != 0 && dot + 1 < name.size();
  }

  [[nodiscard]] static std::size_t trimLeading(std::string_view text) noexcept {
    std::size_t start = 0;
    while (start < text.size() && static_cast<unsigned char>(text[start]) >= LinkText::first_non_ascii) {
      ++start;
    }

    return start;
  }

  [[nodiscard]] static std::size_t trimTrailing(std::string_view text) noexcept {
    auto end = text.size();
    while (end != 0 && (text[end - 1] == '.' || static_cast<unsigned char>(text[end - 1]) >= LinkText::first_non_ascii)) {
      --end;
    }

    return end;
  }

  [[nodiscard]] static bool tokenByte(char byte) noexcept {
    return LinkText::alphanumeric(byte) || std::string_view{"/._-~+@%:"}.contains(byte) || static_cast<unsigned char>(byte) >= LinkText::first_non_ascii;
  }
};

}
