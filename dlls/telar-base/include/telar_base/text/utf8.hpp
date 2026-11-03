#pragma once

#include <algorithm>
#include <string_view>

namespace telar::runtime {

inline std::string_view utf8Prefix(std::string_view text, std::size_t capacity) noexcept {
  auto length = std::min(text.size(), capacity);
  while (length != 0 && length < text.size() && (static_cast<unsigned char>(text[length]) & 0xc0) == 0x80) {
    --length;
  }

  return text.substr(0, length);
}

}
