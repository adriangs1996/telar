#pragma once

#include "binary_fraction.hpp"
#include "radix_number.hpp"
#include "telar_base/memory/allocator.hpp"
#include <bit>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::machines {

struct JsonUnsignedInteger {
  static constexpr unsigned binary128_significand_bits = 113;
  static constexpr unsigned binary128_minimum_normal_exponent = 16382;
  static constexpr unsigned zero_half_exponent = binary128_minimum_normal_exponent + binary128_significand_bits;
  static constexpr unsigned ordinary_half_exponent = binary128_significand_bits + 1;
  static constexpr unsigned hexadecimal_bits = 4;

  [[nodiscard]] static bool integerSyntax(std::string_view text) noexcept {
    return text != "-0" && text.find_first_of(".eE") == std::string_view::npos;
  }

  template <std::unsigned_integral Number, Allocator Memory>
  [[nodiscard]] static Number parse(Memory &memory, std::string_view text, bool allow_float = true) {
    static_assert(std::numeric_limits<Number>::digits <= std::numeric_limits<std::uint16_t>::digits);

    const bool floating = !integerSyntax(text);
    if (floating && !allow_float) {
      invalid();
    }

    const RadixNumber number{memory, text, floating};
    const auto maximum = static_cast<std::uint32_t>(std::numeric_limits<Number>::max());
    const auto integral = number.integerPart(maximum);
    if (number.integral()) {
      if (number.negative() && integral != 0) {
        invalid();
      }

      return static_cast<Number>(integral);
    }

    if (!floating) {
      invalid();
    }

    return static_cast<Number>(rounded(number, integral, maximum));
  }

private:
  [[noreturn]] static void invalid() {
    throw std::invalid_argument{"JSON number is not a representable unsigned integer"};
  }

  template <Allocator Memory>
  static std::uint32_t rounded(const RadixNumber<Memory> &number, std::uint32_t integral, std::uint32_t maximum) {
    if (!number.negative()) {
      if (integral != 0) {
        const auto exponent = binary128_significand_bits - (std::bit_width(integral) - 1);
        const BinaryFraction<ordinary_half_exponent> upper{exponent, number.radix()};
        if (number.compareFraction(upper) <= 0) {
          return integral;
        }
      }

      if (integral < maximum) {
        const auto next = integral + 1;
        const auto exponent = binary128_significand_bits - (std::bit_width(next) - 1) + static_cast<unsigned>(std::has_single_bit(next));
        const BinaryFraction<ordinary_half_exponent> lower{exponent, number.radix()};
        if (number.compareFraction(lower, true) >= 0) {
          return next;
        }
      }
    }

    if (integral == 0 && number.fractionLeadingZeros() >= (zero_half_exponent - 1) / hexadecimal_bits) {
      if (number.radix() == NumberRadix::decimal) {
        static const BinaryFraction<zero_half_exponent> zero{zero_half_exponent};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      } else {
        const BinaryFraction<zero_half_exponent> zero{zero_half_exponent, NumberRadix::hexadecimal};
        if (number.compareFraction(zero) <= 0) {
          return 0;
        }
      }
    }

    invalid();
  }
};

}
