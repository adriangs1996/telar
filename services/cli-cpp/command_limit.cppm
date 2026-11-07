module;
#include <cstddef>
#include <cstdlib>
#include <stdlib.h>
#include <new>
#include <cstring>
#include <cstdio>

#include <cstdint>

#include <cerrno>
#include <unistd.h>


export module telar.cli.command_limit;

import std;

export import telar.cli.output;
export import telar.platform;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: arguments.cppm
export {
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
  inline explicit Cursor(Arguments words) noexcept
      : words_(words) {}

  [[nodiscard]] inline bool empty() const noexcept {
    return words_.empty();
  }

  inline std::optional<std::string_view> next() noexcept {
    if (words_.empty()) {
      return std::nullopt;
    }

    const std::string_view word = words_.front();
    words_ = words_.subspan(1);
    return word;
  }

  inline std::string_view take(const char *missing) {
    const auto word = next();
    if (!word) {
      usage(missing);
    }

    return *word;
  }

  [[nodiscard]] inline Arguments rest() const noexcept {
    return words_;
  }

private:
  Arguments words_;
};

}
}

// Interface: command_io.cppm
export {
namespace telar::runtime::cli {

inline std::string quoteJson(std::string_view text, JsonEscapes escapes = JsonEscapes::standard) {
  std::string result;
  result.reserve(text.size() + 2);
  appendJsonText(result, text, escapes);
  return result;
}

inline void writeBytes(int descriptor, std::span<const Byte> bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      throw std::runtime_error{"WriteFailed"};
    }

    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
}

inline void writeText(std::string_view text, int descriptor = STDOUT_FILENO) {
  writeBytes(descriptor, {reinterpret_cast<const Byte *>(text.data()), text.size()});
}

inline std::string_view textBytes(std::span<const Byte> bytes) {
  return {reinterpret_cast<const char *>(bytes.data()), bytes.size()};
}

inline std::uint64_t randomIdentity() {
  std::uint64_t value = 0;
  while (value == 0) {
    randomBytes(&value, sizeof(value));
  }

  return value;
}

inline const char *jsonBoolean(bool value) {
  return value ? "true" : "false";
}

inline const char *systemErrorName(int code) {
  switch (code) {
  case ENOENT:
    return "FileNotFound";
  case ECONNREFUSED:
    return "ConnectionRefused";
  case EACCES:
  case EPERM:
    return "AccessDenied";
  case ENOTDIR:
    return "NotDir";
  case ENAMETOOLONG:
    return "NameTooLong";
  case ELOOP:
    return "SymLinkLoop";
  default:
    return "InputOutput";
  }
}

inline std::string_view commandErrorName(const std::exception &error) {
  if (const auto *system = dynamic_cast<const SystemError *>(&error)) {
    return systemErrorName(system->code());
  }

  if (std::string_view{error.what()} == "Runtime receive timed out") {
    return "RuntimeTimeout";
  }

  return error.what();
}

}
}

// Interface: command_limit.cppm
export {
namespace telar::runtime::cli {

inline std::string limitDescription(const LimitReach &reach, std::uint64_t hits = 1) {
  std::string output = std::string{reach.name} + ": ";
  const auto noun = reach.noun.empty() ? "" : " " + std::string{reach.noun};
  if (reach.requested) {
    output += std::format("{}{}; limit {}", *reach.requested, noun, reach.value);
  } else if (reach.value == 0) {
    output += "limit reached";
  } else {
    output += std::format("limit {}{} reached", reach.value, noun);
  }

  if (hits > 1) {
    output += std::format(" ({} times)", hits);
  }

  return output;
}

inline void reportCommandLimit(const LimitReach &reach) {
  writeText("telar: Limit reached: " + limitDescription(reach) + "\n", STDERR_FILENO);
}

}
}
