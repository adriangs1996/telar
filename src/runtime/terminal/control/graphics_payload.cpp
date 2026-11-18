module;
#if defined(__aarch64__) && defined(__AARCH64EL__)
#include <arm_neon.h>
#endif

module telar.runtime.terminal.control;

import telar.base.text;
import telar.base.ds;

namespace telar::runtime::control {

  namespace {

    constexpr std::size_t graphics_base64_block_input = 16;
    constexpr std::size_t graphics_base64_block_output = 12;

    // Complete alphabet-only groups have no padding or whitespace state. The
    // caller checks both extents before this exact 16-byte load/12-byte store.
    // A rejected block writes nothing and is handled by the scalar state machine.
    bool decodeGraphicsBlock(const char* input, std::uint8_t* output) noexcept {
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
      if (__builtin_reduce_and(upper | lower | digit | plus | slash) != std::numeric_limits<std::uint8_t>::max()) {
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

    constexpr std::size_t graphics_base64_wide_input = 64;
    constexpr std::size_t graphics_base64_wide_output = 48;

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

    alignas(16) constexpr auto graphics_base64_tables = [] {
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

    GraphicsBase64Lanes graphicsBase64Lanes(uint8x16_t bytes) noexcept {
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
    bool decodeGraphicsWideBlock(const char* input, std::uint8_t* output) noexcept {
#if defined(__aarch64__) && defined(__AARCH64EL__)
      const auto columns = vld4q_u8(reinterpret_cast<const std::uint8_t*>(input));
      const auto first = graphicsBase64Lanes(columns.val[0]);
      const auto second = graphicsBase64Lanes(columns.val[1]);
      const auto third = graphicsBase64Lanes(columns.val[2]);
      const auto fourth = graphicsBase64Lanes(columns.val[3]);
      const auto valid = vreinterpretq_u64_u8(vandq_u8(vandq_u8(first.valid, second.valid), vandq_u8(third.valid, fourth.valid)));
      if ((vgetq_lane_u64(valid, 0) & vgetq_lane_u64(valid, 1)) != std::numeric_limits<std::uint64_t>::max()) {
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

    constexpr auto graphics_base64_digits = [] {
      std::array<std::uint8_t, 256> digits;

      digits.fill(std::numeric_limits<std::uint8_t>::max());
      for (std::size_t index = 0; index < base64::alphabet.size(); ++index) {
        digits[static_cast<std::uint8_t>(base64::alphabet[index])] = static_cast<std::uint8_t>(index);
      }

      return digits;
    }();

  }

  ds::Option<std::size_t> decodeGraphicsPayload(std::string_view encoded, std::span<std::uint8_t> output) noexcept {
    std::array<unsigned, 4> group;
    unsigned count = 0;
    unsigned padding = 0;
    std::size_t written = 0;
    const auto emit = [&](unsigned length) {
      if (length > output.size() - written) {
        return false;
      }

      output[written++] = static_cast<std::uint8_t>((group[0] << 2) | (group[1] >> 4));
      if (length >= 2) {
        output[written++] = static_cast<std::uint8_t>((group[1] << 4) | (group[2] >> 2));
      }

      if (length == 3) {
        output[written++] = static_cast<std::uint8_t>((group[2] << 6) | group[3]);
      }

      return true;
    };

    std::size_t offset = 0;

    while (encoded.size() - offset >= graphics_base64_wide_input && output.size() - written >= graphics_base64_wide_output && decodeGraphicsWideBlock(encoded.data() + offset, output.data() + written)) {
      offset += graphics_base64_wide_input;
      written += graphics_base64_wide_output;
    }

    while (encoded.size() - offset >= graphics_base64_block_input && output.size() - written >= graphics_base64_block_output && decodeGraphicsBlock(encoded.data() + offset, output.data() + written)) {
      offset += graphics_base64_block_input;
      written += graphics_base64_block_output;
    }

    for (std::size_t index = offset; index < encoded.size(); ++index) {
      const auto byte = encoded[index];
      if (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\f') {
        continue;
      }

      if (byte == '=') {
        if (count < 2 || padding == 2 || count + padding >= 4) {
          return ds::none;
        }

        ++padding;
        continue;
      }

      if (padding != 0) {
        return ds::none;
      }

      const auto digit = graphics_base64_digits[static_cast<std::uint8_t>(byte)];
      if (digit == std::numeric_limits<std::uint8_t>::max()) {
        return ds::none;
      }

      group[count++] = static_cast<unsigned>(digit);
      if (count == group.size()) {
        if (!emit(3)) {
          return ds::none;
        }

        count = 0;
      }
    }

    if (count == 1 || (padding != 0 && count + padding != 4)) {
      return ds::none;
    }

    if (count != 0 && !emit(count - 1)) {
      return ds::none;
    }

    return written;
  }

}
