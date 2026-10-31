#pragma once

#include "core/unicode_scalar.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct Utf16Encoding {
  std::size_t invalid_scalar_bytes = 0;
};

struct Utf16Prefix {
  static constexpr char16_t first_high_surrogate = 0xd800;
  static constexpr char16_t last_high_surrogate = 0xdbff;
  static constexpr char16_t first_low_surrogate = 0xdc00;
  static constexpr char16_t last_low_surrogate = 0xdfff;
  static constexpr std::size_t paired_units = 2;
  static constexpr std::size_t paired_bytes = 4;
  static constexpr std::size_t three_byte_scalar = 3;

  std::size_t units = 0;
  std::size_t bytes = 0;
  std::size_t requested_bytes = 0;

  [[nodiscard]] static Utf16Prefix fit(std::u16string_view text, std::size_t capacity, Utf16Encoding encoding = {}) noexcept {
    Utf16Prefix result;
    std::size_t position = 0;

    while (position < text.size()) {
      const auto scalar = text[position];
      const auto paired = scalar >= first_high_surrogate && scalar <= last_high_surrogate &&
                          position + 1 < text.size() &&
                          text[position + 1] >= first_low_surrogate && text[position + 1] <= last_low_surrogate;
      const auto length = paired ? paired_units : std::size_t{1};
      const auto encoded = paired ? paired_bytes : encodedBytes(scalar, encoding);

      if (result.units == position && encoded <= capacity - result.bytes) {
        result.units += length;
        result.bytes += encoded;
      }

      result.requested_bytes += encoded;
      position += length;
    }

    return result;
  }

private:
  [[nodiscard]] static std::size_t encodedBytes(char16_t scalar, Utf16Encoding encoding) noexcept {
    if (!Utf8Scalar::valid(scalar)) {
      return encoding.invalid_scalar_bytes;
    }

    if (scalar <= Utf8Scalar::maximum_codepoints[0]) {
      return 1;
    }

    if (scalar <= Utf8Scalar::maximum_codepoints[1]) {
      return 2;
    }

    return three_byte_scalar;
  }
};

}
