#include "assertions.hpp"
#include "core/memory.hpp"
#include "text/binary_fraction.hpp"
#include "text/json_unsigned_integer.hpp"
#include "text/number_radix.hpp"
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using namespace telar::gui;
using telar::gui::test::require;

template <Allocator Memory>
void rejects(Memory &memory, std::string_view text) {
  try {
    static_cast<void>(JsonUnsignedInteger::parse<std::uint16_t>(memory, text));
  } catch (const std::invalid_argument &) {
    return;
  }

  throw std::runtime_error{"Unrepresentable integer text was accepted"};
}

void binaryFractionsKeepExactDecimalAndHexadecimalDigits() {
  const BinaryFraction<4> fraction{4};
  constexpr std::string_view expected = "0625";
  constexpr std::string_view complement = "9375";
  for (std::size_t index = 0; index < expected.size(); ++index) {
    require(fraction.digit(index) == static_cast<unsigned>(expected[index] - '0'), "binary half intervals must retain exact terminating decimal digits");
    require(fraction.complementDigit(index, NumberRadix::decimal) == static_cast<unsigned>(complement[index] - '0'), "the lower interval must subtract the full fraction from one");
  }

  const BinaryFraction<5> hexadecimal{5, NumberRadix::hexadecimal};
  constexpr unsigned partial_digit = 8;
  require(hexadecimal.size() == 2 && hexadecimal.digit(0) == 0 && hexadecimal.digit(1) == partial_digit, "a binary fraction must retain the partial final hexadecimal digit");
}

void conversionsRetainOriginalNumericSyntaxAndRejectFractionalValues() {
  SystemAllocator memory;
  for (const auto *const text : {"1", "+1", "01", "1.0", "1e0", "100e-2", "0x1.0p0", "0x.8p1"}) {
    require(JsonUnsignedInteger::parse<std::uint16_t>(memory, text) == 1, "numeric strings and integral decimal or hexadecimal floats must retain their value");
  }

  constexpr std::uint16_t separated_integer = 10;
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, "1__0") == separated_integer, "integer syntax must preserve the original internal separator rule");
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, "-0") == 0, "negative zero must remain zero");
  rejects(memory, "1.5");
  rejects(memory, "1.00000000000000000001");
  rejects(memory, "-1");
  rejects(memory, "65536");
  rejects(memory, "_1");
  rejects(memory, "1_");
  rejects(memory, "1e+_0");
}

void binary128TiesRoundToTheIntegerWithoutPlatformFloatingPoint() {
  SystemAllocator memory;
  constexpr auto fraction_digits = (JsonUnsignedInteger::binary128_significand_bits - 1) / JsonUnsignedInteger::hexadecimal_bits;
  const auto upper_tie = std::string{"0x1."} + std::string(fraction_digits, '0') + "8p0";
  const auto upper_outside = std::string{"0x1."} + std::string(fraction_digits, '0') + "81p0";
  const auto lower_tie = std::string{"0x0."} + std::string(fraction_digits, 'f') + "cp0";
  const auto lower_outside = std::string{"0x0."} + std::string(fraction_digits, 'f') + "bp0";
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, upper_tie) == 1, "the upper binary128 midpoint must round to the even integer");
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, lower_tie) == 1, "a power of two must use its narrower lower midpoint");
  rejects(memory, upper_outside);
  rejects(memory, lower_outside);
}

void subnormalBoundariesRoundToZeroAndReleaseTemporaryStorage() {
  SystemAllocator system;
  constexpr std::size_t memory_limit = std::size_t{32} * 1024;
  BudgetAllocator memory{system, memory_limit};
  constexpr auto leading_zeros = (JsonUnsignedInteger::zero_half_exponent - 1) / JsonUnsignedInteger::hexadecimal_bits;
  const auto prefix = std::string{"0x0."} + std::string(leading_zeros, '0');
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, prefix + "1p0") == 0, "values below the smallest subnormal midpoint must become zero");
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, prefix + "2p0") == 0, "the smallest subnormal midpoint must round to even zero");
  require(JsonUnsignedInteger::parse<std::uint16_t>(memory, "-" + prefix + "1p0") == 0, "negative underflow must retain zero conversion");
  rejects(memory, prefix + "3p0");
  require(memory.liveBytes() == 0, "numeric conversion must release every allocator-owned temporary");
}

}

int main() {
  try {
    binaryFractionsKeepExactDecimalAndHexadecimalDigits();
    conversionsRetainOriginalNumericSyntaxAndRejectFractionalValues();
    binary128TiesRoundToTheIntegerWithoutPlatformFloatingPoint();
    subnormalBoundariesRoundToZeroAndReleaseTemporaryStorage();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
