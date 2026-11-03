#pragma once

#include <string_view>

namespace telar::runtime {

inline constexpr char asciiLower(char value) noexcept {
  return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

inline constexpr bool asciiEqualIgnoreCase(std::string_view left, std::string_view right) noexcept {
  if (left.size() != right.size()) {
    return false;
  }
  for (std::size_t index = 0; index < left.size(); ++index) {
    if (asciiLower(left[index]) != asciiLower(right[index])) {
      return false;
    }
  }
  return true;
}

}
