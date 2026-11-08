#pragma once

#include <cstdint>
#include <cstring>

namespace telar::runtime::control {

inline constexpr std::size_t graphics_base64_block_input = 16;
inline constexpr std::size_t graphics_base64_block_output = 12;

// Complete alphabet-only groups have no padding or whitespace state. The
// caller checks both extents before this exact 16-byte load/12-byte store.
// A rejected block writes nothing and is handled by the scalar state machine.
inline bool decodeGraphicsBlock(const char *input, std::uint8_t *output) noexcept {
#if defined(__clang__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  using Bytes = std::uint8_t __attribute__((ext_vector_type(16)));
  using Words = std::uint32_t __attribute__((ext_vector_type(4)));
  Bytes bytes;
  std::memcpy(&bytes, input, sizeof(bytes));
  const Bytes upper = __builtin_bit_cast(Bytes, (bytes >= 'A') & (bytes <= 'Z'));
  const Bytes lower = __builtin_bit_cast(Bytes, (bytes >= 'a') & (bytes <= 'z'));
  const Bytes digit = __builtin_bit_cast(Bytes, (bytes >= '0') & (bytes <= '9'));
  const Bytes plus = __builtin_bit_cast(Bytes, bytes == '+');
  const Bytes slash = __builtin_bit_cast(Bytes, bytes == '/');
  if (__builtin_reduce_and(upper | lower | digit | plus | slash) != UINT8_MAX) {
    return false;
  }
  const Bytes values = ((bytes - 'A') & upper) | ((bytes - 'a' + 26) & lower) | ((bytes - '0' + 52) & digit) | (plus & 62) | (slash & 63);
  // The packed-word form is defined for the two little-endian targets we
  // compile. Other architectures retain the scalar decoder.
  const auto words = __builtin_bit_cast(Words, values);
  const Words decoded = ((words & 0x0000003fu) << 18) | ((words & 0x00003f00u) << 4) | ((words & 0x003f0000u) >> 10) | ((words & 0x3f000000u) >> 24);
  const auto packed = __builtin_bit_cast(Bytes, decoded);
  const Bytes ordered = __builtin_shufflevector(packed, packed, 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 3, 7, 11, 15);
  std::memcpy(output, &ordered, graphics_base64_block_output);
  return true;
#else
  static_cast<void>(input);
  static_cast<void>(output);
  return false;
#endif
}

}
