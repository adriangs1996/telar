#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <type_traits>

// What every command's argument parser shares, as the Zig CLI's `arguments/`
// does. A usage error is an `std::invalid_argument` carrying the Zig error name,
// which `main` prints with the help reference.
namespace telar::runtime::cli {

using Arguments = std::span<char *const>;

[[noreturn]] inline void usage(const char *error) {
  throw std::invalid_argument{error};
}

enum class Sign : std::uint8_t {
  rejected,
  accepted,
};

// Zig's `std.fmt.parseInt` (`Sign::accepted`) or `std.fmt.parseUnsigned`
// (`Sign::rejected`) in base 10: one optional sign, digits with inner
// underscores, and the Zig error names `InvalidCharacter` and `Overflow`. As in
// Zig, an unsigned integer accepts "-0" when signs are accepted.
template <typename Integer>
Integer parseDecimal(std::string_view text, Sign sign) {
  const bool negative = sign == Sign::accepted && text.starts_with('-');
  if (sign == Sign::accepted && (text.starts_with('+') || negative)) {
    text.remove_prefix(1);
  }

  if (text.empty() || text.front() == '_' || text.back() == '_') {
    usage("InvalidCharacter");
  }

  using Unsigned = std::make_unsigned_t<Integer>;
  constexpr auto positive_limit = static_cast<Unsigned>(std::numeric_limits<Integer>::max());
  constexpr auto negative_limit = std::is_signed_v<Integer> ? static_cast<Unsigned>(positive_limit + 1) : Unsigned{0};
  const auto limit = negative ? negative_limit : positive_limit;
  constexpr Unsigned decimal_base = 10;
  Unsigned value = 0;
  for (const char byte : text) {
    if (byte == '_') {
      continue;
    }

    if (byte < '0' || byte > '9') {
      usage("InvalidCharacter");
    }

    const auto digit = static_cast<Unsigned>(byte - '0');
    if (digit > limit || value > (limit - digit) / decimal_base) {
      usage("Overflow");
    }

    value = static_cast<Unsigned>(value * decimal_base + digit);
  }

  if constexpr (std::is_signed_v<Integer>) {
    if (negative) {
      return value == negative_limit ? std::numeric_limits<Integer>::min() : static_cast<Integer>(-static_cast<Integer>(value));
    }
  }

  return static_cast<Integer>(value);
}

template <typename Integer>
Integer parseInt(std::string_view text) {
  return parseDecimal<Integer>(text, Sign::accepted);
}

template <typename Integer>
Integer parseUnsigned(std::string_view text) {
  return parseDecimal<Integer>(text, Sign::rejected);
}

// `std.fmt.parseUnsigned(...) catch null`.
template <typename Integer = std::uint64_t>
std::optional<Integer> maybeUnsigned(std::string_view text) noexcept {
  try {
    return parseUnsigned<Integer>(text);
  } catch (const std::invalid_argument &) {
    return std::nullopt;
  }
}

// `std.fmt.parseUnsigned(...) catch return error.X`.
template <typename Integer = std::uint64_t>
Integer number(std::string_view text, const char *error) {
  const auto value = maybeUnsigned<Integer>(text);
  if (!value) {
    usage(error);
  }

  return *value;
}

// `std.fmt.parseInt(...) catch return error.X`.
template <typename Integer>
Integer signedNumber(std::string_view text, const char *error) {
  try {
    return parseInt<Integer>(text);
  } catch (const std::invalid_argument &) {
    usage(error);
  }
}

// A nonzero identity: tabs, panes, clients and workspaces start at 1.
inline std::uint64_t positive(std::string_view text, const char *error) {
  const auto value = number(text, error);
  if (value == 0) {
    usage(error);
  }

  return value;
}

// The word among `names` that `text` is, as the enum value at its position.
template <typename Enum, std::size_t Size>
Enum choice(std::string_view text, const char *error, const std::array<std::string_view, Size> &names) {
  const auto found = std::ranges::find(names, text);
  if (found == names.end()) {
    usage(error);
  }

  return static_cast<Enum>(found - names.begin());
}

// Zig's `arguments/Cursor.zig`: consumes words left to right; `take` keeps each
// command's own missing-value error.
class Cursor {
public:
  explicit Cursor(Arguments words) noexcept
      : words_(words) {}

  [[nodiscard]] bool empty() const noexcept {
    return words_.empty();
  }

  std::optional<std::string_view> next() noexcept {
    if (words_.empty()) {
      return std::nullopt;
    }

    const std::string_view word = words_.front();
    words_ = words_.subspan(1);
    return word;
  }

  std::string_view take(const char *missing) {
    const auto word = next();
    if (!word) {
      usage(missing);
    }

    return *word;
  }

  [[nodiscard]] Arguments rest() const noexcept {
    return words_;
  }

private:
  Arguments words_;
};

}
