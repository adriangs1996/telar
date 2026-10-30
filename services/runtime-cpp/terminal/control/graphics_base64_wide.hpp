#pragma once

#include "../../text/base64.hpp"
#include <cstddef>
#include <cstdint>

#if defined(__aarch64__) && defined(__AARCH64EL__)
#include <arm_neon.h>
#endif

namespace telar::runtime::control {

inline constexpr std::size_t graphics_base64_wide_input = 64;
inline constexpr std::size_t graphics_base64_wide_output = 48;

#if defined(__aarch64__) && defined(__AARCH64EL__)
struct GraphicsBase64Lanes {
  uint8x16_t values;
  uint8x16_t valid;
};

struct GraphicsBase64Tables {
  std::array<std::uint8_t, 16> high{};
  std::array<std::uint8_t, 16> low{};
  std::array<std::uint8_t, 16> offset{};
};

alignas(16) inline constexpr auto graphics_base64_tables = [] {
  GraphicsBase64Tables tables;
  constexpr unsigned first_group = '+' >> 4;
  for (std::size_t index = 0; index < base64::alphabet.size(); ++index) {
    const auto byte = static_cast<std::uint8_t>(base64::alphabet[index]);
    const auto high = byte >> 4;
    const auto low = byte & 15;
    const auto group = static_cast<std::uint8_t>(1u << (high - first_group));
    tables.high[high] = group;
    tables.low[low] |= group;
    if (byte != '/') {
      tables.offset[high] = static_cast<std::uint8_t>(index - byte);
    }
  }
  return tables;
}();

inline GraphicsBase64Lanes graphicsBase64Lanes(uint8x16_t bytes) noexcept {
  const auto high = vshrq_n_u8(bytes, 4);
  const auto low = vandq_u8(bytes, vdupq_n_u8(15));
  const auto high_groups = vqtbl1q_u8(vld1q_u8(graphics_base64_tables.high.data()), high);
  const auto low_groups = vqtbl1q_u8(vld1q_u8(graphics_base64_tables.low.data()), low);
  const auto valid = vmvnq_u8(vceqq_u8(vandq_u8(high_groups, low_groups), vdupq_n_u8(0)));
  const auto offset = vqtbl1q_u8(vld1q_u8(graphics_base64_tables.offset.data()), high);
  constexpr auto slash_correction = static_cast<std::uint8_t>('/' - '+' - 1);
  const auto correction = vandq_u8(vceqq_u8(bytes, vdupq_n_u8('/')), vdupq_n_u8(slash_correction));
  return {vsubq_u8(vaddq_u8(bytes, offset), correction), valid};
}
#endif

// Four interleaved columns contain sixteen independent base64 groups. Validate
// all columns before storing exactly48bytes; rejection leaves output untouched.
inline bool decodeGraphicsWideBlock(const char *input, std::uint8_t *output) noexcept {
#if defined(__aarch64__) && defined(__AARCH64EL__)
  const auto columns = vld4q_u8(reinterpret_cast<const std::uint8_t *>(input));
  const auto first = graphicsBase64Lanes(columns.val[0]);
  const auto second = graphicsBase64Lanes(columns.val[1]);
  const auto third = graphicsBase64Lanes(columns.val[2]);
  const auto fourth = graphicsBase64Lanes(columns.val[3]);
  const auto valid = vreinterpretq_u64_u8(vandq_u8(vandq_u8(first.valid, second.valid), vandq_u8(third.valid, fourth.valid)));
  if ((vgetq_lane_u64(valid, 0) & vgetq_lane_u64(valid, 1)) != UINT64_MAX) {
    return false;
  }

  const uint8x16x3_t decoded{{
      vorrq_u8(vshlq_n_u8(first.values, 2), vshrq_n_u8(second.values, 4)),
      vorrq_u8(vshlq_n_u8(second.values, 4), vshrq_n_u8(third.values, 2)),
      vorrq_u8(vshlq_n_u8(third.values, 6), fourth.values),
  }};
  vst3q_u8(output, decoded);
  return true;
#else
  static_cast<void>(input);
  static_cast<void>(output);
  return false;
#endif
}

}
