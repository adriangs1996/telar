#pragma once

#include "telar_base/text/identifier.hpp"
#include <array>
#include <cstdint>
#include <string_view>

namespace telar::runtime::plugins {

using PackageDigest = std::array<std::uint8_t, 32>;

constexpr std::uint64_t stableId(std::string_view name) noexcept {
  std::uint64_t hash = 0xcbf29ce484222325;
  for (const unsigned char byte : name) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}

inline bool validEntrypoint(std::string_view path) noexcept {
  if (path.empty() || path.front() == '/') {
    return false;
  }
  for (;;) {
    const auto separator = path.find_first_of("/\\");
    const auto part = path.substr(0, separator);
    if (part.empty() || part == "." || part == "..") {
      return false;
    }
    if (separator == std::string_view::npos) {
      return true;
    }
    path.remove_prefix(separator + 1);
  }
}

}
