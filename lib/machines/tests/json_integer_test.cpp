#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.machines;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime::machines;

  template <Allocator Memory>
  void rejects(Memory& memory, std::string_view text) {
    try {
      static_cast<void>(JsonUnsignedInteger::parse<std::uint16_t>(memory, text));
    } catch (const std::invalid_argument&) {
      return;
    }

    check(false, "unrepresentable integer text was accepted");
  }

  void conversionsRetainOriginalNumericSyntaxAndRejectFractionalValues() {
    telar::testing::TestMemory adapter;
    telar::Memory& memory = adapter;

    for (const auto* const text : {"1", "+1", "01", "1.0", "1e0", "100e-2", "0x1.0p0", "0x.8p1"}) {
      check(JsonUnsignedInteger::parse<std::uint16_t>(memory, text) == 1, "numeric strings and integral decimal or hexadecimal floats must retain their value");
    }

    constexpr std::uint16_t separated_integer = 10;

    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "1__0") == separated_integer, "integer syntax must preserve the original internal separator rule");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "-0") == 0, "negative zero must remain zero");
    rejects(memory, "1.5");
    rejects(memory, "1.00000000000000000001");
    rejects(memory, "-1");
    rejects(memory, "65536");
    rejects(memory, "_1");
    rejects(memory, "1_");
    rejects(memory, "1e+_0");
  }

  void binary128TiesRoundToTheIntegerWithoutPlatformFloatingPoint() {
    telar::testing::TestMemory adapter;
    telar::Memory& memory = adapter;
    constexpr auto fraction_digits = (JsonUnsignedInteger::binary128_significand_bits - 1) / JsonUnsignedInteger::hexadecimal_bits;
    const auto upper_tie = std::string{"0x1."} + std::string(fraction_digits, '0') + "8p0";
    const auto upper_outside = std::string{"0x1."} + std::string(fraction_digits, '0') + "81p0";
    const auto lower_tie = std::string{"0x0."} + std::string(fraction_digits, 'f') + "cp0";
    const auto lower_outside = std::string{"0x0."} + std::string(fraction_digits, 'f') + "bp0";

    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, upper_tie) == 1, "the upper binary128 midpoint must round to the even integer");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, lower_tie) == 1, "a power of two must use its narrower lower midpoint");
    rejects(memory, upper_outside);
    rejects(memory, lower_outside);
  }

  void subnormalBoundariesRoundToZeroAndReleaseTemporaryStorage() {
    SystemAllocator system;
    constexpr std::size_t memory_limit = std::size_t{32} * 1024;
    BudgetAllocator budget{system, memory_limit};
    MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    constexpr auto leading_zeros = (JsonUnsignedInteger::zero_half_exponent - 1) / JsonUnsignedInteger::hexadecimal_bits;
    const auto prefix = std::string{"0x0."} + std::string(leading_zeros, '0');

    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, prefix + "1p0") == 0, "values below the smallest subnormal midpoint must become zero");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, prefix + "2p0") == 0, "the smallest subnormal midpoint must round to even zero");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "-" + prefix + "1p0") == 0, "negative underflow must retain zero conversion");
    rejects(memory, prefix + "3p0");
    check(budget.liveBytes() == 0, "numeric conversion must release every allocator-owned temporary");
  }

  // An exponent is read digit by digit into a bounded count: one far past any representable
  // value must neither wrap into a small exponent (2^64 wraps to zero) nor overflow, which
  // UBSan reports in the sanitize preset.
  void hugeExponentsStayHuge() {
    telar::testing::TestMemory adapter;
    telar::Memory& memory = adapter;

    rejects(memory, "1e99999999999999999999");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "1e-99999999999999999999") == 0, "a value below the smallest subnormal becomes zero");
    rejects(memory, "1e18446744073709551616");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "1e-18446744073709551616") == 0, "a value below the smallest subnormal becomes zero");
    check(JsonUnsignedInteger::parse<std::uint16_t>(memory, "0e99999999999999999999") == 0, "zero stays zero at any exponent");
  }

  // A machine identity is never zero, whatever the entropy source yields first.
  void machineIdentityRetriesZeroEntropy() {
    struct ZeroThenEntropy {
      std::size_t zero_draws = 0;
      std::size_t draws = 0;

      void fill(std::span<std::uint8_t> bytes) {
        std::ranges::fill(bytes, draws++ < zero_draws ? std::uint8_t{0} : std::uint8_t{0xa5});
      }
    };

    for (const std::size_t zero_draws : {std::size_t{0}, std::size_t{1}, std::size_t{3}}) {
      ZeroThenEntropy random{.zero_draws = zero_draws};
      const auto identity = MachineId::generate(random);

      check(identity.value() != 0 && identity.value() <= MachineId::maximum_value);
      check(MachineId::parse(identity.format().view()) == identity);
    }
  }

  const telar::testing::Case case_numeric_syntax{"json_integer.numeric_syntax", conversionsRetainOriginalNumericSyntaxAndRejectFractionalValues};
  const telar::testing::Case case_binary128_ties{"json_integer.binary128_ties", binary128TiesRoundToTheIntegerWithoutPlatformFloatingPoint};
  const telar::testing::Case case_subnormal_boundaries{"json_integer.subnormal_boundaries", subnormalBoundariesRoundToZeroAndReleaseTemporaryStorage};
  const telar::testing::Case case_huge_exponents{"json_integer.bounds_huge_exponents", hugeExponentsStayHuge};
  const telar::testing::Case case_machine_identity_zero_entropy{"machine_id.generate_retries_zero_entropy", machineIdentityRetriesZeroEntropy};

}
