#pragma once

#include <charconv>
#include <concepts>
#include <expected>
#include <limits>
#include <optional>
#include <string_view>
#include <system_error>

// Textual so headers that cannot import modules, as the kitty control parser, share it; the
// telar.base.text module re-exports it.
namespace telar::runtime {

  enum class NumberError : unsigned char {
    invalid_character,
    overflow,
  };

  // Digits in `base` (2 to 16) with '_' only between them, as Zig's parseUnsigned reads them, worth
  // at most `limit`. The first failing digit decides the error, as it does there.
  template <std::unsigned_integral Integer>
  constexpr std::expected<Integer, NumberError> unsignedNumber(std::string_view text, Integer limit = std::numeric_limits<Integer>::max(), unsigned base = 10) noexcept {
    if (text.empty() || text.front() == '_' || text.back() == '_') {
      return std::unexpected{NumberError::invalid_character};
    }

    Integer value = 0;

    for (const auto character : text) {
      if (character == '_') {
        continue;
      }

      const int digit = character >= '0' && character <= '9' ? character - '0' : character >= 'a' && character <= 'f' ? character - 'a' + 10
                                                                             : character >= 'A' && character <= 'F'   ? character - 'A' + 10
                                                                                                                      : -1;
      if (digit < 0 || static_cast<unsigned>(digit) >= base) {
        return std::unexpected{NumberError::invalid_character};
      }

      const auto worth = static_cast<Integer>(digit);
      if (worth > limit || value > (limit - worth) / base) {
        return std::unexpected{NumberError::overflow};
      }

      value = static_cast<Integer>(value * base + worth);
    }

    return value;
  }

  // A decimal number with optional '_' separators between its digits; none when it holds anything
  // else or exceeds Integer.
  template <std::unsigned_integral Integer>
  constexpr std::optional<Integer> unsignedDecimal(std::string_view text) noexcept {
    const auto value = unsignedNumber<Integer>(text);

    return value ? std::optional{*value} : std::nullopt;
  }

  // `text` read whole as an Integer in `base`, as std::from_chars reads it; none when any byte is
  // left over or the value does not fit.
  template <std::integral Integer>
  constexpr std::optional<Integer> parseExact(std::string_view text, int base = 10) noexcept {
    Integer value{};
    const auto* const end = text.data() + text.size();
    const auto [ptr, error] = std::from_chars(text.data(), end, value, base);
    if (error != std::errc{} || ptr != end || text.empty()) {
      return std::nullopt;
    }

    return value;
  }

}
