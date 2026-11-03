#pragma once

#include "telar_base/text/json.hpp"
#include <array>

namespace telar::runtime {

template <Allocator Memory>
class SchemaVersion {
public:
  static bool isOne(Memory &memory, const JsonValue &value) {
    String<Memory> text{AllocatorRef<char, Memory>{memory}};
    if (value.encoded().starts_with('"')) {
      value.string(text);
    } else {
      text = value.encoded();
    }
    return SchemaVersion{memory}.parse(text);
  }

private:
  explicit SchemaVersion(Memory &memory) : digits_(AllocatorRef<char, Memory>{memory}) {}

  bool parse(std::string_view text) {
    const bool floating = text.find_first_of(".eE") != std::string_view::npos;
    if (text.starts_with('+')) {
      text.remove_prefix(1);
    }
    if (text.empty() || text.starts_with('-') || text.front() == '_' || text.back() == '_') {
      return false;
    }

    const bool hexadecimal = floating && (text.starts_with("0x") || text.starts_with("0X"));
    if (hexadecimal) {
      text.remove_prefix(2);
    }
    const unsigned base = hexadecimal ? 16 : 10;
    const auto exponent_at = text.find_first_of(hexadecimal ? "pP" : "eE");
    const auto mantissa = text.substr(0, exponent_at);
    if (!readMantissa(mantissa, base, floating)) {
      return false;
    }

    std::int64_t exponent = 0;
    if (exponent_at != std::string_view::npos && (!floating || !readExponent(text.substr(exponent_at + 1), exponent))) {
      return false;
    }
    const auto first = digits_.find_first_not_of('0');
    if (first == String<Memory>::npos) {
      return false;
    }

    exponent += integer_digits_ - static_cast<std::int64_t>(first);
    if (hexadecimal && (digits_.size() - (first / 4) * 4) / 4 > 32) {
      truncateHexFallback();
    }
    const auto significant = std::string_view{digits_}.substr(first);
    if (!floating) {
      return exponent == 1 && compare(significant, "1") == 0;
    }

    // Zig coerces JSON versions through binary128. Compare its exact rounding
    // interval around one; double precision would accept different versions.
    const auto lower = hexadecimal ? std::string_view{binary_lower.data(), binary_lower.size()} : decimal_lower;
    const auto upper = hexadecimal ? std::string_view{binary_upper.data(), binary_upper.size()} : decimal_upper;
    if (exponent == 0) {
      return compare(significant, lower) >= 0;
    }
    return exponent == 1 && compare(significant, upper) <= 0;
  }

  void truncateHexFallback() {
    // The reference's long-hex fallback stops at a decimal coefficient of
    // 10^31, so its discarded tail cannot participate in binary128 rounding.
    __uint128_t coefficient = 0;
    std::size_t consumed = 0;
    while (consumed < digits_.size() && coefficient < hex_fallback_coefficient) {
      for (unsigned bit = 0; bit < 4; ++bit) {
        coefficient = coefficient * 2 + static_cast<unsigned>(digits_[consumed++] - '0');
      }
    }
    digits_.resize(consumed);
  }

  bool readMantissa(std::string_view text, unsigned base, bool floating) {
    bool point = false;
    for (std::size_t index = 0; index < text.size(); ++index) {
      const char byte = text[index];
      if (byte == '_') {
        if (index == 0 || index + 1 == text.size() || (floating && (digit(text[index - 1]) >= base || digit(text[index + 1]) >= base))) {
          return false;
        }
        continue;
      }
      if (byte == '.' && floating && !point) {
        point = true;
        continue;
      }
      const auto value = digit(byte);
      if (value >= base) {
        return false;
      }

      if (base == 16) {
        for (unsigned shift = 4; shift != 0; --shift) {
          digits_ += static_cast<char>('0' + ((value >> (shift - 1)) & 1));
        }
      } else {
        digits_ += byte;
      }
      if (!point) {
        integer_digits_ += base == 16 ? 4 : 1;
      }
    }
    return !digits_.empty();
  }

  static bool readExponent(std::string_view text, std::int64_t &value) noexcept {
    const bool negative = text.starts_with('-');
    if (negative || text.starts_with('+')) {
      text.remove_prefix(1);
    }
    if (text.empty()) {
      return false;
    }

    for (std::size_t index = 0; index < text.size(); ++index) {
      if (text[index] == '_') {
        if (index == 0 || index + 1 == text.size() || digit(text[index - 1]) >= 10 || digit(text[index + 1]) >= 10) {
          return false;
        }
        continue;
      }
      const auto number = digit(text[index]);
      if (number >= 10) {
        return false;
      }
      value = std::min(exponent_limit, value * 10 + number);
    }
    value = negative ? -value : value;
    return true;
  }

  static unsigned digit(char byte) noexcept {
    if (byte >= '0' && byte <= '9') {
      return static_cast<unsigned>(byte - '0');
    }
    if (byte >= 'a' && byte <= 'f') {
      return static_cast<unsigned>(byte - 'a' + 10);
    }
    if (byte >= 'A' && byte <= 'F') {
      return static_cast<unsigned>(byte - 'A' + 10);
    }
    return 16;
  }

  static int compare(std::string_view left, std::string_view right) noexcept {
    for (std::size_t index = 0; index < std::max(left.size(), right.size()); ++index) {
      const auto first = index < left.size() ? left[index] : '0';
      const auto second = index < right.size() ? right[index] : '0';
      if (first != second) {
        return first < second ? -1 : 1;
      }
    }
    return 0;
  }

  static constexpr std::int64_t exponent_limit = 1'000'000;
  static constexpr auto hex_fallback_coefficient = [] {
    __uint128_t value = 1;
    for (unsigned power = 0; power < 31; ++power) {
      value *= 10;
    }
    return value;
  }();
  static constexpr std::string_view decimal_lower = "999999999999999999999999999999999951851751390319103673600551435376817036547458794615295119001530110836029052734375";
  static constexpr std::string_view decimal_upper = "100000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125";
  static constexpr auto binary_lower = [] {
    std::array<char, 114> digits;
    digits.fill('1');
    return digits;
  }();
  static constexpr auto binary_upper = [] {
    std::array<char, 114> digits;
    digits.fill('0');
    digits.front() = '1';
    digits.back() = '1';
    return digits;
  }();
  String<Memory> digits_;
  std::int64_t integer_digits_ = 0;
};

}
