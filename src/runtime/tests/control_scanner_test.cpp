#include "terminal/control/styled_ordinary.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <string>

using namespace telar::runtime::control;

static void require(bool condition) {
  if (!condition) {
    std::abort();
  }
}

static std::span<const std::uint8_t> bytes(std::string_view input) {
  return {reinterpret_cast<const std::uint8_t *>(input.data()), input.size()};
}

static void retainedControlBoundaries() {
  for (const auto boundary : {std::string{"\x05"}, std::string{"\x1b[5n"}}) {
    const std::string input = "ab\x1b[0m" + boundary + std::string(32, 'x');
    styled_detail::ControlScanner scanner{bytes(input)};
    require(scanner.next(0) == 2);
    require(scanner.next(6) == 6);
    require(styledOrdinaryLength(bytes(input), 2) == 6);
  }
}

static void repeatedOffsets() {
  std::string input(257, 'x');
  for (const auto position : {1u, 7u, 15u, 16u, 31u, 32u, 63u, 64u, 129u, 256u}) {
    input[position] = '\x1b';
  }
  for (const auto position : {2u, 6u, 14u, 17u, 30u, 33u, 62u, 65u, 128u, 255u}) {
    input[position] = '\x05';
  }

  for (std::size_t length = 0; length <= input.size(); ++length) {
    const auto text = std::string_view{input}.substr(0, length);
    styled_detail::ControlScanner scanner{bytes(text)};
    const auto check = [&](std::size_t offset) {
      const auto found = text.find_first_of("\x1b\x05", offset);
      require(scanner.next(offset) == (found == std::string_view::npos ? length : found));
    };
    for (std::size_t offset = 0; offset <= length; ++offset) {
      check(offset);
    }
    for (std::size_t offset = length; offset != 0; --offset) {
      check(offset - 1);
    }
  }
}

static void grammarBoundaries() {
  for (const auto count : {24u, 25u}) {
    for (const auto parameter : {'9', ';'}) {
      const std::string input = "ab\x1b[" + std::string(count, parameter) + "mTAIL";
      require(styledOrdinaryLength(bytes(input), 2) == (count == 24 ? input.size() : 2));
    }
  }

  for (const auto body : {"?5n", "31:2m", "0", "1;2H"}) {
    const std::string input = std::string{"ab\x1b["} + body;
    require(styledOrdinaryLength(bytes(input), 2) == 2);
  }
}

static void repeatedSgrBoundaries() {
  const std::array styles{"\x1b[m", "\x1b[0m", "\x1b[1;32m", "\x1b[12345m", "\x1b[123456m"};
  for (const auto first : styles) {
    for (const auto second : styles) {
      const std::string prefix = std::string{"ab"} + first + "A" + second + "B\x1b[4mC" + first + "D" + second + "E";
      for (const auto boundary : {"\x05", "\x1b[5n", "\x1b[?6n", "\x1b[1;32n", "\x1b]52;c;?\a", "\x1b[31:2m", "\x1b[1;"}) {
        const std::string input = prefix + boundary;
        require(styledOrdinaryLength(bytes(input), 0) == prefix.size());
        require(styledOrdinaryLength(bytes(input), 2) == prefix.size());
      }
      for (const auto suffix : {"", "x", "TAIL", "\r\n", "\x80", "\xf0\x9f"}) {
        const std::string input = prefix + first + suffix;
        require(styledOrdinaryLength(bytes(input), 0) == input.size());
      }
    }
  }
}

int main() {
  retainedControlBoundaries();
  repeatedOffsets();
  grammarBoundaries();
  repeatedSgrBoundaries();
  std::puts("Control scanner retained-window tests passed");
}
