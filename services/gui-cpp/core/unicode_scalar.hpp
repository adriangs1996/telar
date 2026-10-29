#pragma once

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct Utf8Scalar {
  static constexpr std::uint32_t maximum_codepoint = 0x10ffff;
  static constexpr std::uint32_t first_surrogate = 0xd800;
  static constexpr std::uint32_t last_surrogate = 0xdfff;
  static constexpr unsigned continuation_bits = 6;
  static constexpr unsigned continuation_prefix = 0x80;
  static constexpr unsigned continuation_mask = 0x3f;
  static constexpr std::array<unsigned, 4> leading_prefixes{0, 0xc0, 0xe0, 0xf0};
  static constexpr std::array<unsigned, 4> leading_masks{0x7f, 0x1f, 0x0f, 0x07};
  static constexpr std::array<std::uint32_t, 4> minimum_codepoints{0, 0x80, 0x800, 0x10000};
  static constexpr std::array<std::uint32_t, 4> maximum_codepoints{0x7f, 0x7ff, 0xffff, maximum_codepoint};

  std::array<char, 4> bytes{};
  std::size_t length = 0;

  [[nodiscard]] static constexpr std::size_t sequenceLength(unsigned char leading) noexcept {
    return leading < continuation_prefix ? std::size_t{1} : static_cast<std::size_t>(std::countl_one(leading));
  }

  [[nodiscard]] std::string_view view() const noexcept {
    return {bytes.data(), length};
  }

  [[nodiscard]] static constexpr bool valid(std::uint32_t codepoint) noexcept {
    return codepoint <= maximum_codepoint && (codepoint < first_surrogate || codepoint > last_surrogate);
  }

  [[nodiscard]] static Utf8Scalar encode(std::uint32_t codepoint) {
    if (!valid(codepoint)) {
      throw std::invalid_argument{"Invalid Unicode scalar"};
    }

    Utf8Scalar result;
    while (codepoint > maximum_codepoints[result.length]) {
      ++result.length;
    }

    const auto continuation_count = result.length;
    result.bytes[0] = static_cast<char>(leading_prefixes[continuation_count] | (codepoint >> (continuation_bits * continuation_count)));
    for (std::size_t index = 0; index < continuation_count; ++index) {
      const auto shift = continuation_bits * (continuation_count - index - 1);
      result.bytes[index + 1] = static_cast<char>(continuation_prefix | ((codepoint >> shift) & continuation_mask));
    }

    ++result.length;

    return result;
  }

  [[nodiscard]] static std::uint32_t decode(std::string_view text) {
    const auto decoded = read(text);
    switch (decoded.error) {
    case DecodeError::none:
      return decoded.value;
    case DecodeError::length:
      throw std::invalid_argument{"Expected one UTF-8 scalar"};
    case DecodeError::leading_byte:
      throw std::invalid_argument{"Invalid UTF-8 leading byte"};
    case DecodeError::continuation_byte:
      throw std::invalid_argument{"Invalid UTF-8 continuation byte"};
    case DecodeError::scalar:
      throw std::invalid_argument{"Invalid or overlong UTF-8 scalar"};
    }

    throw std::invalid_argument{"Invalid Unicode decoding state"};
  }

  [[nodiscard]] static std::optional<std::uint32_t> tryDecode(std::string_view text) noexcept {
    const auto decoded = read(text);
    if (decoded.error != DecodeError::none) {
      return std::nullopt;
    }

    return decoded.value;
  }

private:
  enum class DecodeError : std::uint8_t {
    none,
    length,
    leading_byte,
    continuation_byte,
    scalar,
  };

  struct Decoded {
    std::uint32_t value = 0;
    DecodeError error = DecodeError::none;
  };

  [[nodiscard]] static Decoded read(std::string_view text) noexcept {
    if (text.empty() || text.size() > leading_masks.size()) {
      return {.error = DecodeError::length};
    }

    const auto length = text.size();
    const auto first = static_cast<unsigned char>(text.front());
    const auto prefix_mask = ~leading_masks[length - 1] & std::uint8_t{0xff};
    if ((first & prefix_mask) != leading_prefixes[length - 1]) {
      return {.error = DecodeError::leading_byte};
    }

    auto codepoint = static_cast<std::uint32_t>(first & leading_masks[length - 1]);
    auto continuations = text;
    continuations.remove_prefix(1);
    for (const auto byte : continuations) {
      const auto continuation = static_cast<unsigned char>(byte);
      constexpr unsigned prefix_mask = 0xc0;
      if ((continuation & prefix_mask) != continuation_prefix) {
        return {.error = DecodeError::continuation_byte};
      }

      codepoint = (codepoint << continuation_bits) | (continuation & continuation_mask);
    }

    if (!valid(codepoint) || codepoint < minimum_codepoints[length - 1]) {
      return {.error = DecodeError::scalar};
    }

    return {.value = codepoint};
  }
};

}
