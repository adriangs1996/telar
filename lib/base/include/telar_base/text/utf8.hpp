#pragma once

#include <cstdint>
#include <exception>
#include <string_view>

namespace telar {

  enum class Utf8Validation : std::uint8_t {
    valid,
    invalid_leading,
    invalid_continuation,
    invalid_scalar,
  };

  namespace utf8 {

    // Whether a byte continues a sequence: 10xxxxxx.
    constexpr bool isContinuation(std::uint8_t byte) noexcept {
      constexpr std::uint8_t mask = 0xc0;
      constexpr std::uint8_t tag = 0x80;

      return (byte & mask) == tag;
    }

    // How many bytes the sequence a leading byte starts holds, or 0 for a byte that starts none:
    // 0xc0 and 0xc1 start only overlong pairs, and the bytes past 0xf4 scalars past U+10FFFF.
    constexpr std::size_t sequenceLength(std::uint8_t lead) noexcept {
      constexpr std::uint8_t pair_first = 0xc2;
      constexpr std::uint8_t pair_last = 0xdf;
      constexpr std::uint8_t triple_first = 0xe0;
      constexpr std::uint8_t triple_last = 0xef;
      constexpr std::uint8_t quad_first = 0xf0;
      constexpr std::uint8_t quad_last = 0xf4;

      if (lead >= pair_first && lead <= pair_last) {
        return 2;
      }

      if (lead >= triple_first && lead <= triple_last) {
        return 3;
      }

      if (lead >= quad_first && lead <= quad_last) {
        return 4;
      }

      return 0;
    }

    // Whether the second byte of a sequence keeps it a scalar: not overlong, not a surrogate, and
    // not past U+10FFFF, which only these leading bytes can break.
    constexpr bool scalarSecond(std::uint8_t lead, std::uint8_t second) noexcept {
      constexpr std::uint8_t overlong_triple = 0xe0;
      constexpr std::uint8_t surrogate_triple = 0xed;
      constexpr std::uint8_t overlong_quad = 0xf0;
      constexpr std::uint8_t last_quad = 0xf4;
      constexpr std::uint8_t triple_second_low = 0xa0;
      constexpr std::uint8_t quad_second_low = 0x90;
      constexpr std::uint8_t last_quad_second_high = 0x8f;

      if (lead == overlong_triple) {
        return second >= triple_second_low;
      }

      if (lead == surrogate_triple) {
        return second < triple_second_low;
      }

      if (lead == overlong_quad) {
        return second >= quad_second_low;
      }

      return lead != last_quad || second <= last_quad_second_high;
    }

  }

  inline Utf8Validation inspectUtf8(std::string_view value) noexcept {
    constexpr std::uint8_t ascii_end = 0x80;
    std::size_t index = 0;

    while (index < value.size()) {
      const auto lead = static_cast<std::uint8_t>(value[index]);
      if (lead < ascii_end) {
        ++index;
        continue;
      }

      const auto length = utf8::sequenceLength(lead);
      if (length == 0 || length > value.size() - index) {
        return Utf8Validation::invalid_leading;
      }

      for (std::size_t offset = 1; offset < length; ++offset) {
        if (!utf8::isContinuation(static_cast<std::uint8_t>(value[index + offset]))) {
          return Utf8Validation::invalid_continuation;
        }
      }

      if (!utf8::scalarSecond(lead, static_cast<std::uint8_t>(value[index + 1]))) {
        return Utf8Validation::invalid_scalar;
      }

      index += length;
    }

    return Utf8Validation::valid;
  }

  // Bytes that break a format's rules: the wire protocol, a configuration or a record on disk.
  struct EncodingError final : std::exception { // NOLINT(clang-diagnostic-weak-vtables): the wire's headers throw it without a library to define it in

    explicit EncodingError(const char* message)
        : message_{message} {}

    [[nodiscard]] const char* what() const noexcept override {
      return message_;
    }

  private:
    const char* message_;
  };

  inline void validateUtf8(std::string_view value) {
    switch (inspectUtf8(value)) {
    case Utf8Validation::valid:
      return;
    case Utf8Validation::invalid_leading:
      throw EncodingError{"Invalid UTF-8"};
    case Utf8Validation::invalid_continuation:
      throw EncodingError{"Invalid UTF-8 continuation"};
    case Utf8Validation::invalid_scalar:
      throw EncodingError{"Invalid UTF-8 scalar"};
    }
  }

}

namespace telar::runtime {

  inline std::string_view utf8Prefix(std::string_view text, std::size_t capacity) noexcept {
    auto length = text.size() < capacity ? text.size() : capacity;

    while (length != 0 && length < text.size() && utf8::isContinuation(static_cast<std::uint8_t>(text[length]))) {
      --length;
    }

    text.remove_suffix(text.size() - length);
    return text;
  }

}
