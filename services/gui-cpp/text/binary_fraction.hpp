#pragma once

#include "number_radix.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui {

template <std::size_t MaximumExponent>
class BinaryFraction {
public:
  explicit BinaryFraction(std::size_t exponent, NumberRadix radix = NumberRadix::decimal) {
    if (exponent == 0 || exponent > MaximumExponent) {
      throw std::out_of_range{"Binary fraction exponent exceeds capacity"};
    }

    if (radix == NumberRadix::hexadecimal) {
      length_ = (exponent + hexadecimal_bits - 1) / hexadecimal_bits;
      const auto trailing_bits = exponent % hexadecimal_bits;
      digits_[length_ - 1] = static_cast<std::uint8_t>(trailing_bits == 0 ? 1 : 1U << (hexadecimal_bits - trailing_bits));

      return;
    }

    if (radix != NumberRadix::decimal) {
      throw std::invalid_argument{"Unsupported binary fraction radix"};
    }

    length_ = exponent;
    deriveDecimal(exponent);
  }

  [[nodiscard]] unsigned digit(std::size_t position) const noexcept {
    return position < length_ ? digits_[position] : 0;
  }

  [[nodiscard]] unsigned complementDigit(std::size_t position, NumberRadix radix) const noexcept {
    if (position >= length_) {
      return 0;
    }

    return static_cast<unsigned>(radix) - digit(position) - static_cast<unsigned>(position + 1 < length_);
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return length_;
  }

private:
  static constexpr unsigned decimal_radix = 10;
  static constexpr unsigned hexadecimal_bits = 4;
  static constexpr unsigned decimal_limb_digits = 9;
  static constexpr std::uint64_t decimal_limb_base = 1'000'000'000;
  static constexpr std::uint64_t half_decimal_radix = decimal_radix / 2;
  static constexpr std::size_t limb_capacity = ((MaximumExponent + decimal_limb_digits - 1) / decimal_limb_digits) + 1;

  void deriveDecimal(std::size_t exponent) {
    std::array<std::uint32_t, limb_capacity> limbs{};
    limbs.front() = 1;
    std::size_t count = 1;
    for (std::size_t power = 0; power < exponent; ++power) {
      std::uint64_t carry = 0;
      for (auto &limb : std::span{limbs}.first(count)) {
        const auto product = (static_cast<std::uint64_t>(limb) * half_decimal_radix) + carry;
        limb = static_cast<std::uint32_t>(product % decimal_limb_base);
        carry = product / decimal_limb_base;
      }

      if (carry != 0) {
        limbs[count++] = static_cast<std::uint32_t>(carry);
      }
    }

    auto position = exponent;
    for (auto limb : std::span{limbs}.first(count)) {
      for (unsigned digit = 0; digit < decimal_limb_digits && position != 0; ++digit) {
        digits_[--position] = static_cast<std::uint8_t>(limb % decimal_radix);
        limb /= decimal_radix;
      }
    }
  }

  std::array<std::uint8_t, MaximumExponent> digits_{};
  std::size_t length_ = 0;
};

}
