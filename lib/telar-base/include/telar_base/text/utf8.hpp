#pragma once

#include <algorithm>
#include <cstdint>
#include <string_view>

namespace telar {

  enum class Utf8Validation : std::uint8_t {
    valid,
    invalid_leading,
    invalid_continuation,
    invalid_scalar
  };

  inline Utf8Validation inspectUtf8(std::string_view value) noexcept {
    std::size_t index = 0;
    while (index < value.size()) {
      const auto lead = static_cast<std::uint8_t>(value[index]);
      if (lead < 0x80) {
        ++index;
        continue;
      }

      const std::size_t length = lead >= 0xc2 && lead <= 0xdf   ? 2
                                 : lead >= 0xe0 && lead <= 0xef ? 3
                                 : lead >= 0xf0 && lead <= 0xf4 ? 4
                                                                : 0;
      if (length == 0 || length > value.size() - index) {
        return Utf8Validation::invalid_leading;
      }

      for (std::size_t i = 1; i < length; ++i) {
        const auto byte = static_cast<std::uint8_t>(value[index + i]);
        if (byte < 0x80 || byte > 0xbf) {
          return Utf8Validation::invalid_continuation;
        }
      }
      const auto second = static_cast<std::uint8_t>(value[index + 1]);
      if ((lead == 0xe0 && second < 0xa0) || (lead == 0xed && second >= 0xa0) ||
          (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second > 0x8f)) {
        return Utf8Validation::invalid_scalar;
      }
      index += length;
    }

    return Utf8Validation::valid;
  }

}

namespace telar::runtime {

  inline std::string_view utf8Prefix(std::string_view text, std::size_t capacity) noexcept {
    auto length = std::min(text.size(), capacity);
    while (length != 0 && length < text.size() && (static_cast<unsigned char>(text[length]) & 0xc0) == 0x80) {
      --length;
    }

    return text.substr(0, length);
  }

}
