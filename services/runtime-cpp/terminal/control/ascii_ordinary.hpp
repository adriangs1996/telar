#pragma once

#include "styled_ordinary.hpp"
#include <algorithm>
#include <cstdint>
#include <span>

namespace telar::runtime::control::ascii_detail {

inline constexpr std::size_t gate_bytes = styled_detail::vector_bytes * 2;
inline constexpr std::size_t codepoint_capacity = 4096;
inline constexpr std::uint8_t non_ascii_first = 0x80;

#if defined(__aarch64__) && defined(__AARCH64EL__)
using ByteVector = uint8x16_t;
inline constexpr unsigned match_bits = 4;

inline ByteVector load(const std::uint8_t *input) noexcept { return vld1q_u8(input); }

inline std::uint64_t stopMask(ByteVector bytes) noexcept {
  const auto controls = vorrq_u8(vceqq_u8(bytes, vdupq_n_u8(styled_detail::enquiry)), vceqq_u8(bytes, vdupq_n_u8(styled_detail::escape)));
  const auto stops = vorrq_u8(controls, vcgeq_u8(bytes, vdupq_n_u8(non_ascii_first)));
  return vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(stops), match_bits)), 0);
}

inline void widenBlock(ByteVector bytes, std::uint32_t *output) noexcept {
  const auto low = vmovl_u8(vget_low_u8(bytes));
  const auto high = vmovl_high_u8(bytes);
  vst1q_u32(output, vmovl_u16(vget_low_u16(low)));
  vst1q_u32(output + 4, vmovl_high_u16(low));
  vst1q_u32(output + 8, vmovl_u16(vget_low_u16(high)));
  vst1q_u32(output + 12, vmovl_high_u16(high));
}
#elif defined(__SSE2__)
using ByteVector = __m128i;
inline constexpr unsigned match_bits = 1;

inline ByteVector load(const std::uint8_t *input) noexcept { return _mm_loadu_si128(reinterpret_cast<const __m128i *>(input)); }

inline std::uint64_t stopMask(ByteVector bytes) noexcept {
  const auto controls = _mm_or_si128(_mm_cmpeq_epi8(bytes, _mm_set1_epi8(styled_detail::enquiry)), _mm_cmpeq_epi8(bytes, _mm_set1_epi8(styled_detail::escape)));
  return static_cast<unsigned>(_mm_movemask_epi8(_mm_or_si128(controls, bytes)));
}

inline void widenBlock(ByteVector bytes, std::uint32_t *output) noexcept {
  const auto zero = _mm_setzero_si128();
  const auto low = _mm_unpacklo_epi8(bytes, zero);
  const auto high = _mm_unpackhi_epi8(bytes, zero);
  _mm_storeu_si128(reinterpret_cast<__m128i *>(output), _mm_unpacklo_epi16(low, zero));
  _mm_storeu_si128(reinterpret_cast<__m128i *>(output + 4), _mm_unpackhi_epi16(low, zero));
  _mm_storeu_si128(reinterpret_cast<__m128i *>(output + 8), _mm_unpacklo_epi16(high, zero));
  _mm_storeu_si128(reinterpret_cast<__m128i *>(output + 12), _mm_unpackhi_epi16(high, zero));
}
#endif

inline bool eligible(std::span<const std::uint8_t> input) noexcept {
  if (input.size() < gate_bytes) {
    return false;
  }
#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
  return stopMask(load(input.data())) == 0 && stopMask(load(input.data() + styled_detail::vector_bytes)) == 0;
#else
  for (const auto byte : input.first(gate_bytes)) {
    if (byte >= non_ascii_first || byte == styled_detail::escape || byte == styled_detail::enquiry) {
      return false;
    }
  }
  return true;
#endif
}

// Complete vector stores may initialize scratch after the accepted prefix,
// but every read and write stays within both supplied spans.
inline std::size_t widen(std::span<const std::uint8_t> input, std::span<std::uint32_t> output) noexcept {
  const auto capacity = std::min(input.size(), output.size());
  std::size_t offset = 0;
#if (defined(__aarch64__) && defined(__AARCH64EL__)) || defined(__SSE2__)
  while (capacity - offset >= styled_detail::vector_bytes) {
    const auto bytes = load(input.data() + offset);
    const auto stops = stopMask(bytes);
    widenBlock(bytes, output.data() + offset);
    if (stops != 0) {
      return offset + std::countr_zero(stops) / match_bits;
    }
    offset += styled_detail::vector_bytes;
  }
#endif

  while (offset < capacity) {
    const auto byte = input[offset];
    if (byte >= non_ascii_first || byte == styled_detail::escape || byte == styled_detail::enquiry) {
      break;
    }
    output[offset++] = byte;
  }
  return offset;
}

}
