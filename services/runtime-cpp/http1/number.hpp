#pragma once

#include "../text/ascii.hpp"
#include <limits>
#include <optional>
#include <string_view>

namespace telar::runtime {

template <unsigned Base>
std::optional<std::size_t> parseHttpNumber(std::string_view text) noexcept {
  // The existing relay accepts signed zero and interior underscores in lengths.
  static_assert(Base == 10 || Base == 16);
  if (text.empty()) {
    return std::nullopt;
  }

  const bool negative = text.front() == '-';
  if (negative || text.front() == '+') {
    text.remove_prefix(1);
  }
  if (text.empty() || text.front() == '_' || text.back() == '_') {
    return std::nullopt;
  }

  std::size_t value = 0;
  for (const char character : text) {
    if (character == '_') {
      continue;
    }
    const char lower = asciiLower(character);
    const auto digit = static_cast<unsigned>(lower >= 'a' && lower <= 'f' ? lower - 'a' + 10 : lower - '0');
    if (digit >= Base || value > (std::numeric_limits<std::size_t>::max() - digit) / Base) {
      return std::nullopt;
    }
    value = value * Base + digit;
  }

  return negative && value != 0 ? std::nullopt : std::optional{value};
}

}
