import std;
import telar.runtime.terminal.control;
import telar.testing;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::control;
  using styled_detail::Isa;

  std::span<const std::uint8_t> bytes(std::string_view input) {
    return {reinterpret_cast<const std::uint8_t*>(input.data()), input.size()};
  }

  // The scan of each instruction set: the target's vectors, which production runs, and the byte
  // loop of a target without them.
  template <Isa Set>
  std::size_t styledLength(std::span<const std::uint8_t> input, std::size_t prefix) {
    return Set == Isa::vector ? styledOrdinaryLength(input, prefix) : styledOrdinaryLengthScalar(input, prefix);
  }

  template <Isa Set>
  void retainedControlBoundaries() {
    for (const auto& boundary : {std::string{"\x05"}, std::string{"\x1b[5n"}}) {
      const std::string input = "ab\x1b[0m" + boundary + std::string(32, 'x');
      styled_detail::ControlScanner<Set> scanner{bytes(input)};

      check(scanner.next(0) == 2);
      check(scanner.next(6) == 6);
      check(styledLength<Set>(bytes(input), 2) == 6);
    }
  }

  template <Isa Set>
  void repeatedOffsets() {
    std::string input(257, 'x');

    for (const auto position : {1u, 7u, 15u, 16u, 31u, 32u, 63u, 64u, 129u, 256u}) {
      input[position] = '\x1b';
    }

    for (const auto position : {2u, 6u, 14u, 17u, 30u, 33u, 62u, 65u, 128u, 255u}) {
      input[position] = '\x05';
    }

    for (std::size_t length = 0; length <= input.size(); ++length) {
      const auto text = std::string_view{input}.substr(0, length);
      styled_detail::ControlScanner<Set> scanner{bytes(text)};
      const auto scanFrom = [&](std::size_t offset) {
        const auto found = text.find_first_of("\x1b\x05", offset);

        check(scanner.next(offset) == (found == std::string_view::npos ? length : found));
      };

      for (std::size_t offset = 0; offset <= length; ++offset) {
        scanFrom(offset);
      }

      for (std::size_t offset = length; offset != 0; --offset) {
        scanFrom(offset - 1);
      }
    }
  }

  template <Isa Set>
  void grammarBoundaries() {
    for (const auto count : {24u, 25u}) {
      for (const auto parameter : {'9', ';'}) {
        const std::string input = "ab\x1b[" + std::string(count, parameter) + "mTAIL";

        check(styledLength<Set>(bytes(input), 2) == (count == 24 ? input.size() : 2));
      }
    }

    for (const auto body : {"?5n", "31:2m", "0", "1;2H"}) {
      const std::string input = std::string{"ab\x1b["} + body;

      check(styledLength<Set>(bytes(input), 2) == 2);
    }
  }

  template <Isa Set>
  void repeatedSgrBoundaries() {
    const telar::ds::Array styles{"\x1b[m", "\x1b[0m", "\x1b[1;32m", "\x1b[12345m", "\x1b[123456m"};

    for (const auto first : styles) {
      for (const auto second : styles) {
        const std::string prefix = std::string{"ab"} + first + "A" + second + "B\x1b[4mC" + first + "D" + second + "E";

        for (const auto boundary : {"\x05", "\x1b[5n", "\x1b[?6n", "\x1b[1;32n", "\x1b]52;c;?\a", "\x1b[31:2m", "\x1b[1;"}) {
          const std::string input = prefix + boundary;

          check(styledLength<Set>(bytes(input), 0) == prefix.size());
          check(styledLength<Set>(bytes(input), 2) == prefix.size());
        }

        for (const auto suffix : {"", "x", "TAIL", "\r\n", "\x80", "\xf0\x9f"}) {
          const std::string input = prefix + first + suffix;

          check(styledLength<Set>(bytes(input), 0) == input.size());
        }
      }
    }
  }

  template <Isa Set>
  void scans() {
    retainedControlBoundaries<Set>();
    repeatedOffsets<Set>();
    grammarBoundaries<Set>();
    repeatedSgrBoundaries<Set>();
  }

  const telar::testing::Case case_scans_vector{
      "control_scanner.scans_vector",
      [] {
        scans<Isa::vector>();
      },
  };
  const telar::testing::Case case_scans_scalar{
      "control_scanner.scans_scalar",
      [] {
        scans<Isa::scalar>();
      },
  };

}
