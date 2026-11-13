#pragma once

#include "tbc/view.hpp"

#include "telar_base/text/base64.hpp"
#include <algorithm>

namespace telar::runtime {

// The name, terminated in the caller's destination.
inline tbc::view<const char *, tbc::lt::a> copyGraphicsName(std::span<const std::uint8_t> decoded, tbc::view<std::span<std::uint8_t>, tbc::lt::a> destination) noexcept {
  if (decoded.empty() || decoded.size() >= destination.size() || std::find(decoded.begin(), decoded.end(), 0) != decoded.end()) {
    return nullptr;
  }
  std::copy(decoded.begin(), decoded.end(), destination.begin());
  destination[decoded.size()] = 0;
  return reinterpret_cast<const char *>(destination.data());
}

inline tbc::view<const char *, tbc::lt::a> decodeGraphicsName(std::string_view encoded, tbc::view<std::span<std::uint8_t>, tbc::lt::a> destination) noexcept {
  if (destination.empty()) {
    return nullptr;
  }

  const auto length = base64::decode(encoded, destination.first(destination.size() - 1));
  if (!length || *length == 0 || std::find(destination.begin(), destination.begin() + *length, 0) != destination.begin() + *length) {
    return nullptr;
  }

  destination[*length] = 0;
  return reinterpret_cast<const char *>(destination.data());
}

}
