#pragma once

#include <concepts>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::runtime {

template <std::unsigned_integral Integer>
std::optional<Integer> unsignedDecimal(std::string_view text) noexcept {
  if (text.empty() || text.front() == '_' || text.back() == '_') {
    return std::nullopt;
  }

  constexpr Integer base = 10;
  Integer value = 0;
  for (const auto character : text) {
    if (character == '_') {
      continue;
    }
    if (character < '0' || character > '9') {
      return std::nullopt;
    }

    const auto digit = static_cast<Integer>(character - '0');
    if (value > (std::numeric_limits<Integer>::max() - digit) / base) {
      return std::nullopt;
    }

    value = value * base + digit;
  }

  return value;
}

}
