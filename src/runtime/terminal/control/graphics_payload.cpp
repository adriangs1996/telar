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
    bool decodeGraphicsBlock(std::span<const char, graphics_base64_block_input> input, std::span<std::uint8_t, graphics_base64_block_output> output) noexcept {
#if defined(__clang__) && defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      using Bytes = std::uint8_t __attribute__((ext_vector_type(16)));
      using Words = std::uint32_t __attribute__((ext_vector_type(4)));
      ds::Array<char, graphics_base64_block_input> loaded{};

      std::ranges::copy(input, loaded.dataMut());
      const auto bytes = __builtin_bit_cast(Bytes, loaded);
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
      const Words decoded = ((words & 0x0000003fU) << 18) | ((words & 0x00003f00U) << 4) | ((words & 0x003f0000U) >> 10) | ((words & 0x3f000000U) >> 24);
      const auto packed = __builtin_bit_cast(Bytes, decoded);
      const Bytes ordered = __builtin_shufflevector(packed, packed, 2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, 3, 7, 11, 15);

      const auto stored = __builtin_bit_cast(ds::Array<std::uint8_t, graphics_base64_block_input>, ordered);

      std::ranges::copy(stored.view().first<graphics_base64_block_output>(), output.begin());
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

    // Indexed by a byte's high or low nibble.
    struct GraphicsBase64Tables {
      static constexpr std::size_t nibbles = 16;

      ds::Array<std::uint8_t, nibbles> high{};
      ds::Array<std::uint8_t, nibbles> low{};
      ds::Array<std::uint8_t, nibbles> offset{};
    };

    alignas(16) constexpr auto graphics_base64_tables = [] {
      GraphicsBase64Tables tables;
      constexpr unsigned low_nibble = 0x0f;
      constexpr unsigned first_group = static_cast<unsigned>('+') >> 4U;

      for (std::size_t index = 0; index < base64::alphabet.size(); ++index) {
        const auto byte = static_cast<std::uint8_t>(base64::alphabet[index]);
        const auto high = static_cast<unsigned>(byte) >> 4U;
        const auto low = static_cast<unsigned>(byte) & low_nibble;
        const auto group = static_cast<std::uint8_t>(1U << (high - first_group));

        tables.high.atMut(high) = group;
        tables.low.atMut(low) |= group;
        if (byte != '/') {
          tables.offset.atMut(high) = static_cast<std::uint8_t>(index - byte);
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

      return {.values = vsubq_u8(vaddq_u8(bytes, offset), correction), .valid = valid};
    }
#endif

    // Four interleaved columns contain sixteen independent base64 groups. Validate
    // all columns before storing exactly48bytes; rejection leaves output untouched.
    bool decodeGraphicsWideBlock(std::span<const char, graphics_base64_wide_input> input, std::span<std::uint8_t, graphics_base64_wide_output> output) noexcept {
#if defined(__aarch64__) && defined(__AARCH64EL__)
      const auto columns = vld4q_u8(reinterpret_cast<const std::uint8_t*>(input.data())); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): vld4q_u8 loads from a pointer to bytes, which may alias the chars
      const auto first = graphicsBase64Lanes(columns.val[0]);
      const auto second = graphicsBase64Lanes(columns.val[1]);
      const auto third = graphicsBase64Lanes(columns.val[2]);
      const auto fourth = graphicsBase64Lanes(columns.val[3]);
      const auto valid = vreinterpretq_u64_u8(vandq_u8(vandq_u8(first.valid, second.valid), vandq_u8(third.valid, fourth.valid)));
      if ((vgetq_lane_u64(valid, 0) & vgetq_lane_u64(valid, 1)) != std::numeric_limits<std::uint64_t>::max()) {
        return false;
      }

      const uint8x16x3_t decoded{
          {
              vorrq_u8(vshlq_n_u8(first.values, 2), vshrq_n_u8(second.values, 4)),
              vorrq_u8(vshlq_n_u8(second.values, 4), vshrq_n_u8(third.values, 2)),
              vorrq_u8(vshlq_n_u8(third.values, 6), fourth.values),
          },
      };

      vst3q_u8(output.data(), decoded);
      return true;
#else
      static_cast<void>(input);
      static_cast<void>(output);
      return false;
#endif
    }

    constexpr auto graphics_base64_digits = [] {
      ds::Array<std::uint8_t, std::numeric_limits<std::uint8_t>::max() + 1> digits{};

      digits.fill(std::numeric_limits<std::uint8_t>::max());
      for (std::size_t index = 0; index < base64::alphabet.size(); ++index) {
        digits.atMut(static_cast<std::uint8_t>(base64::alphabet[index])) = static_cast<std::uint8_t>(index);
      }

      return digits;
    }();

  }

  namespace {

    constexpr std::size_t base64_group_digits = 4;

    using Base64Group = ds::Array<unsigned, base64_group_digits>;

    // Writes the first `length` bytes a group's digits spell, if output has room for them.
    [[gnu::always_inline]] inline bool emitGroup(const Base64Group& group, unsigned length, std::span<std::uint8_t> output, std::size_t& written) noexcept {
      constexpr unsigned sextet_bits = 6;

      if (length > output.size() - written) {
        return false;
      }

      output[written++] = static_cast<std::uint8_t>((group[0] << 2U) | (group[1] >> 4U));
      if (length >= 2) {
        output[written++] = static_cast<std::uint8_t>((group[1] << 4U) | (group[2] >> 2U));
      }

      if (length == 3) {
        output[written++] = static_cast<std::uint8_t>((group[2] << sextet_bits) | group[3]);
      }

      return true;
    }

    // Decodes the whole vector blocks at the front of the input, and returns how much of it they took.
    [[gnu::always_inline]] inline std::size_t decodeBlocks(std::span<const char> input, std::span<std::uint8_t> output, std::size_t& written) noexcept {
      std::size_t offset = 0;

      while (input.size() - offset >= graphics_base64_wide_input && output.size() - written >= graphics_base64_wide_output && decodeGraphicsWideBlock(input.subspan(offset).first<graphics_base64_wide_input>(), output.subspan(written).first<graphics_base64_wide_output>())) {
        offset += graphics_base64_wide_input;
        written += graphics_base64_wide_output;
      }

      while (input.size() - offset >= graphics_base64_block_input && output.size() - written >= graphics_base64_block_output && decodeGraphicsBlock(input.subspan(offset).first<graphics_base64_block_input>(), output.subspan(written).first<graphics_base64_block_output>())) {
        offset += graphics_base64_block_input;
        written += graphics_base64_block_output;
      }

      return offset;
    }

    constexpr bool base64Space(char byte) noexcept {
      return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\f';
    }

    // Padding follows at least two digits of a group, and at most two pads complete it.
    constexpr bool paddingFits(unsigned count, unsigned padding) noexcept {
      return count >= 2 && padding != 2 && count + padding < base64_group_digits;
    }

  }

  ds::Option<std::size_t> decodeGraphicsPayload(std::string_view encoded, std::span<std::uint8_t> output) noexcept {
    Base64Group group{};
    unsigned count = 0;
    unsigned padding = 0;
    std::size_t written = 0;
    const auto offset = decodeBlocks(std::span<const char>{encoded}, output, written);

    for (std::size_t index = offset; index < encoded.size(); ++index) {
      const auto byte = encoded[index];
      if (base64Space(byte)) {
        continue;
      }

      if (byte == '=') {
        if (!paddingFits(count, padding)) {
          return ds::none;
        }

        ++padding;
        continue;
      }

      const auto digit = graphics_base64_digits[static_cast<std::uint8_t>(byte)];
      if (padding != 0 || digit == std::numeric_limits<std::uint8_t>::max()) {
        return ds::none;
      }

      group.atMut(count++) = static_cast<unsigned>(digit);
      if (count == group.size()) {
        if (!emitGroup(group, 3, output, written)) {
          return ds::none;
        }

        count = 0;
      }
    }

    if (count == 1 || (padding != 0 && count + padding != base64_group_digits)) {
      return ds::none;
    }

    if (count != 0 && !emitGroup(group, count - 1, output, written)) {
      return ds::none;
    }

    return written;
  }

}
