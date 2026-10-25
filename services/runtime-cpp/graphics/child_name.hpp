#pragma once

#include "../text/base64.hpp"
#include <algorithm>

namespace telar::runtime {

inline const char *decodeGraphicsName(std::string_view encoded, std::span<std::uint8_t> destination) noexcept {
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
