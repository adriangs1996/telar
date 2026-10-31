#pragma once

#include "parameters.hpp"
#include <array>
#include <bit>
#include <climits>
#include <cstring>
#include <span>

#if defined(__aarch64__) && defined(__AARCH64EL__)
#include <arm_neon.h>
#elif defined(__SSE2__)
#include <emmintrin.h>
#endif

namespace telar::runtime::control {
namespace styled_detail {
enum class Control : std::uint8_t { enquiry = 0x05, escape = 0x1b };
inline constexpr auto enquiry = static_cast<std::uint8_t>(Control::enquiry);
inline constexpr auto escape = static_cast<std::uint8_t>(Control::escape);
inline constexpr std::size_t vector_bytes = 16;

inline constexpr bool numericSgrByte(std::uint8_t byte) noexcept {
  const auto relative = static_cast<unsigned>(byte) - static_cast<unsigned>('0');
  return relative <= static_cast<unsigned>(';' - '0') && byte != ':';
}

// Entries copy complete, already validated sequences including ESC[ and m.
// Only little-endian callers use the masked prefix representation.
class ShortSgrCache {
public:
  static constexpr std::size_t capacity = sizeof(std::uint64_t);

  std::size_t match(std::uint64_t word) const noexcept {
    for (const auto &entry : entries_) {
      if ((word & entry.mask) == entry.pattern) {
        return entry.length;
      }
    }
    return 0;
  }

  void remember(std::uint64_t word, std::size_t length) noexcept {
    if (length < 3 || length > capacity) {
      return;
    }

    const auto mask = UINT64_MAX >> ((capacity - length) * CHAR_BIT);
    entries_[next_entry_] = {.pattern = word & mask, .mask = mask, .length = length};
    next_entry_ = (next_entry_ + 1) % entries_.size();
  }

private:
  struct Entry {
    std::uint64_t pattern = UINT64_MAX;
    std::uint64_t mask = 0;
    std::size_t length = 0;
  };

  std::array<Entry, 2> entries_{};
  std::size_t next_entry_ = 0;
};

class ControlScanner {
public:
  explicit ControlScanner(std::span<const std::uint8_t> input) noexcept : input_(input) {}

  std::size_t next(std::size_t offset) noexcept {
    while (input_.size() - offset >= vector_bytes) {
      std::uint64_t candidates;
      if (offset >= window_begin_ && offset < window_end_) {
        candidates = matches_ & (UINT64_MAX << ((offset - window_begin_) * match_bits));
      } else {
#if defined(__aarch64__) && defined(__AARCH64EL__)
        const auto bytes = vld1q_u8(input_.data() + offset);
        const auto matches = vorrq_u8(vceqq_u8(bytes, vdupq_n_u8(enquiry)), vceqq_u8(bytes, vdupq_n_u8(escape)));
        const auto packed = vshrn_n_u16(vreinterpretq_u16_u8(matches), match_bits);
        matches_ = vget_lane_u64(vreinterpret_u64_u8(packed), 0);
#elif defined(__SSE2__)
        const auto bytes = _mm_loadu_si128(reinterpret_cast<const __m128i *>(input_.data() + offset));
        const auto matches = _mm_or_si128(_mm_cmpeq_epi8(bytes, _mm_set1_epi8(enquiry)), _mm_cmpeq_epi8(bytes, _mm_set1_epi8(escape)));
        matches_ = static_cast<unsigned>(_mm_movemask_epi8(matches));
#else
        break;
#endif
        window_begin_ = offset;
        window_end_ = offset + vector_bytes;
        candidates = matches_;
      }
      if (candidates != 0) {
        return window_begin_ + std::countr_zero(candidates) / match_bits;
      }
      offset = window_end_;
    }

    while (offset < input_.size() && input_[offset] != enquiry && input_[offset] != escape) {
      ++offset;
    }
    return offset;
  }

private:
#if defined(__aarch64__) && defined(__AARCH64EL__)
  static constexpr unsigned match_bits = 4;
#else
  static constexpr unsigned match_bits = 1;
#endif
  std::span<const std::uint8_t> input_;
  std::uint64_t matches_ = 0;
  std::size_t window_begin_ = 0;
  std::size_t window_end_ = 0;
};

}

// Search from the supplied offset, crossing only complete bounded numeric SGRs.
// Every other ESC and every ENQ remains a native controller boundary.
inline std::size_t styledOrdinaryLength(std::span<const std::uint8_t> input, std::size_t prefix) noexcept {
  styled_detail::ControlScanner scanner{input};
  styled_detail::ShortSgrCache cache;
  auto length = scanner.next(prefix);
  while (input.size() - length >= 3) {
    std::uint64_t word = 0;
    if constexpr (std::endian::native == std::endian::little) {
      if (input.size() - length >= styled_detail::ShortSgrCache::capacity) {
        std::memcpy(&word, input.data() + length, sizeof(word));
        if (const auto cached_length = cache.match(word); cached_length != 0) {
          length = scanner.next(length + cached_length);
          continue;
        }
      }
    }
    if (input[length] != styled_detail::escape || input[length + 1] != '[') {
      break;
    }

    auto end = length + 2;
    const auto limit = end + std::min(input.size() - end, Parameters::capacity + 1);
    while (end < limit && styled_detail::numericSgrByte(input[end])) {
      ++end;
    }
    if (end == limit || input[end] != 'm') {
      break;
    }

    if constexpr (std::endian::native == std::endian::little) {
      const auto sequence_length = end + 1 - length;
      if (sequence_length <= styled_detail::ShortSgrCache::capacity && input.size() - length >= styled_detail::ShortSgrCache::capacity) {
        cache.remember(word, sequence_length);
      }
    }
    length = end + 1;
    length = scanner.next(length);
  }
  return length;
}

}
