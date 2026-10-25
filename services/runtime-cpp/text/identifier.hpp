#pragma once

#include <algorithm>
#include <string_view>

namespace telar::runtime {

inline bool validIdentifier(std::string_view name) noexcept {
  if (name.empty() || name.front() == '.' || name.back() == '.' || name.contains("..")) {
    return false;
  }

  return std::ranges::all_of(name, [](unsigned char byte) {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_';
  });
}

}
