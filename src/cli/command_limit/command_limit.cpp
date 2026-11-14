module;
#include "tbc/view.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <stdlib.h>

#include <cstdint>

#include <cerrno>
#include <unistd.h>

module telar.cli.command_limit;

import telar.sys.posix;
import telar.wire.vocabulary;

namespace telar::runtime::cli {

  [[noreturn]] void usage(const char* error) {
    throw std::invalid_argument{error};
  }

  enum class Sign : std::uint8_t {
    rejected,
    accepted,
  };

  // A signed (`Sign::accepted`) or unsigned (`Sign::rejected`) integer in base
  // 10: one optional sign, digits with inner underscores, and the error names
  // `InvalidCharacter` and `Overflow`. An unsigned integer accepts "-0" when
  // signs are accepted.
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
    const auto parsed = unsignedNumber<Unsigned>(text, limit);
    if (!parsed) {
      usage(parsed.error() == NumberError::overflow ? "Overflow" : "InvalidCharacter");
    }

    const auto value = *parsed;

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

  template <typename Integer>
  std::optional<Integer> maybeUnsigned(std::string_view text) noexcept {
    try {
      return parseUnsigned<Integer>(text);
    } catch (const std::invalid_argument&) {
      return std::nullopt;
    }
  }

  template <typename Integer>
  Integer number(std::string_view text, const char* error) {
    const auto value = maybeUnsigned<Integer>(text);
    if (!value) {
      usage(error);
    }

    return *value;
  }

  template <typename Integer>
  Integer signedNumber(std::string_view text, const char* error) {
    try {
      return parseInt<Integer>(text);
    } catch (const std::invalid_argument&) {
      usage(error);
    }
  }

  std::uint64_t positive(std::string_view text, const char* error) {
    const auto value = number(text, error);
    if (value == 0) {
      usage(error);
    }

    return value;
  }

  template <typename Enum, std::size_t Size>
  Enum choice(std::string_view text, const char* error, const std::array<std::string_view, Size>& names) {
    const auto found = std::ranges::find(names, text);
    if (found == names.end()) {
      usage(error);
    }

    return static_cast<Enum>(found - names.begin());
  }

  std::string quoteJson(std::string_view text, JsonEscapes escapes) {
    std::string result;

    result.reserve(text.size() + 2);
    appendJsonText(result, text, escapes);
    return result;
  }

  void writeBytes(int descriptor, std::span<const Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::write(descriptor, bytes.data(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        throw std::runtime_error{"WriteFailed"};
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }
  }

  void writeText(std::string_view text, int descriptor) {
    writeBytes(descriptor, {reinterpret_cast<const Byte*>(text.data()), text.size()});
  }

  std::string_view textBytes(std::span<const Byte> bytes) {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()};
  }

  std::uint64_t randomIdentity() {
    std::uint64_t value = 0;

    while (value == 0) {
      randomBytes(&value, sizeof(value));
    }

    return value;
  }

  const char* jsonBoolean(bool value) {
    return value ? "true" : "false";
  }

  std::string_view commandErrorName(const std::exception& error) {
    if (const auto* system = dynamic_cast<const SystemError*>(&error)) {
      return sys::errorName(system->code());
    }

    if (std::string_view{error.what()} == "Runtime receive timed out") {
      return "RuntimeTimeout";
    }

    return error.what();
  }

  std::string limitDescription(const LimitReach& reach, std::uint64_t hits) {
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

  void reportCommandLimit(const LimitReach& reach) {
    writeText("telar: Limit reached: " + limitDescription(reach) + "\n", STDERR_FILENO);
  }

  template int parseInt<int>(std::string_view text);
  template long parseInt<long>(std::string_view text);
  template long long parseInt<long long>(std::string_view text);
  template unsigned short parseInt<unsigned short>(std::string_view text);
  template unsigned int parseInt<unsigned int>(std::string_view text);
  template unsigned long parseInt<unsigned long>(std::string_view text);
  template unsigned long long parseInt<unsigned long long>(std::string_view text);

  template unsigned short parseUnsigned<unsigned short>(std::string_view text);
  template std::optional<unsigned short> maybeUnsigned<unsigned short>(std::string_view text) noexcept;
  template unsigned short number<unsigned short>(std::string_view text, const char* error);
  template unsigned int parseUnsigned<unsigned int>(std::string_view text);
  template std::optional<unsigned int> maybeUnsigned<unsigned int>(std::string_view text) noexcept;
  template unsigned int number<unsigned int>(std::string_view text, const char* error);
  template unsigned long parseUnsigned<unsigned long>(std::string_view text);
  template std::optional<unsigned long> maybeUnsigned<unsigned long>(std::string_view text) noexcept;
  template unsigned long number<unsigned long>(std::string_view text, const char* error);
  template unsigned long long parseUnsigned<unsigned long long>(std::string_view text);
  template std::optional<unsigned long long> maybeUnsigned<unsigned long long>(std::string_view text) noexcept;
  template unsigned long long number<unsigned long long>(std::string_view text, const char* error);

  template int signedNumber<int>(std::string_view text, const char* error);
  template long signedNumber<long>(std::string_view text, const char* error);
  template long long signedNumber<long long>(std::string_view text, const char* error);

  template PaneDirection choice<PaneDirection, 4>(std::string_view text, const char* error, const std::array<std::string_view, 4>& names);
  template AgentStatus choice<AgentStatus, 6>(std::string_view text, const char* error, const std::array<std::string_view, 6>& names);
  template AgentSessionFileKind choice<AgentSessionFileKind, 3>(std::string_view text, const char* error, const std::array<std::string_view, 3>& names);
  template AgentReportState choice<AgentReportState, 9>(std::string_view text, const char* error, const std::array<std::string_view, 9>& names);
  template AgentCommandPhase choice<AgentCommandPhase, 2>(std::string_view text, const char* error, const std::array<std::string_view, 2>& names);
  template AgentBlockedReason choice<AgentBlockedReason, 5>(std::string_view text, const char* error, const std::array<std::string_view, 5>& names);

  Cursor::Cursor(tbc::view<Arguments, tbc::lt::a> words) noexcept
      : words_(words) {}

  bool Cursor::empty() const noexcept {
    return words_.empty();
  }

  tbc::view<std::optional<std::string_view>, tbc::lt::a> Cursor::next() noexcept {
    if (words_.empty()) {
      return std::nullopt;
    }

    const std::string_view word = words_.front();

    words_ = words_.subspan(1);
    return word;
  }

  tbc::view<std::string_view, tbc::lt::a> Cursor::take(const char* missing) {
    const auto word = next();
    if (!word) {
      usage(missing);
    }

    return *word;
  }

  tbc::view<Arguments, tbc::lt::a> Cursor::rest() const noexcept {
    return words_;
  }

}
