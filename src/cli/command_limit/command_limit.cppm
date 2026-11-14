module;
#include <unistd.h>

export module telar.cli.command_limit;

import std;
import telar.tbc;

import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.json;
import telar.vocabulary;
import telar.platform.primitives;
import telar.cli.output;
import telar.platform.error;

// Interface: arguments.cppm
export {
  // What every command's argument parser shares. A usage error is an
  // `std::invalid_argument` carrying the error name, which `main` prints with the
  // help reference.
  namespace telar::runtime::cli {

    using Arguments = std::span<char* const>;

    [[noreturn]] void usage(const char* error);

    // The integer parsers are instantiated in the implementation unit for every
    // standard integer type they accept, so that any width a caller names exists on
    // every platform.
    template <typename Integer>
    Integer parseInt(std::string_view text);

    template <typename Integer>
    Integer parseUnsigned(std::string_view text);

    // `std.fmt.parseUnsigned(...) catch null`.
    template <typename Integer = std::uint64_t>
    std::optional<Integer> maybeUnsigned(std::string_view text) noexcept;

    // `std.fmt.parseUnsigned(...) catch return error.X`.
    template <typename Integer = std::uint64_t>
    Integer number(std::string_view text, const char* error);

    // `std.fmt.parseInt(...) catch return error.X`.
    template <typename Integer>
    Integer signedNumber(std::string_view text, const char* error);

    extern template int parseInt<int>(std::string_view text);
    extern template long parseInt<long>(std::string_view text);
    extern template long long parseInt<long long>(std::string_view text);
    extern template unsigned short parseInt<unsigned short>(std::string_view text);
    extern template unsigned int parseInt<unsigned int>(std::string_view text);
    extern template unsigned long parseInt<unsigned long>(std::string_view text);
    extern template unsigned long long parseInt<unsigned long long>(std::string_view text);

    extern template unsigned short parseUnsigned<unsigned short>(std::string_view text);
    extern template std::optional<unsigned short> maybeUnsigned<unsigned short>(std::string_view text) noexcept;
    extern template unsigned short number<unsigned short>(std::string_view text, const char* error);
    extern template unsigned int parseUnsigned<unsigned int>(std::string_view text);
    extern template std::optional<unsigned int> maybeUnsigned<unsigned int>(std::string_view text) noexcept;
    extern template unsigned int number<unsigned int>(std::string_view text, const char* error);
    extern template unsigned long parseUnsigned<unsigned long>(std::string_view text);
    extern template std::optional<unsigned long> maybeUnsigned<unsigned long>(std::string_view text) noexcept;
    extern template unsigned long number<unsigned long>(std::string_view text, const char* error);
    extern template unsigned long long parseUnsigned<unsigned long long>(std::string_view text);
    extern template std::optional<unsigned long long> maybeUnsigned<unsigned long long>(std::string_view text) noexcept;
    extern template unsigned long long number<unsigned long long>(std::string_view text, const char* error);

    extern template int signedNumber<int>(std::string_view text, const char* error);
    extern template long signedNumber<long>(std::string_view text, const char* error);
    extern template long long signedNumber<long long>(std::string_view text, const char* error);

    // A nonzero identity: tabs, panes, clients and workspaces start at 1.
    std::uint64_t positive(std::string_view text, const char* error);

    // The word among `names` that `text` is, as the enum value at its position. The
    // implementation unit instantiates it for the protocol enums that commands parse.
    template <typename Enum, std::size_t Size>
    Enum choice(std::string_view text, const char* error, const std::array<std::string_view, Size>& names);

    // Consumes words left to right; `take` keeps each command's own missing-value
    // error.
    // Walks a command's words, region `a`; the words it hands out view them.
    class Cursor {
    public:
      explicit Cursor(tbc::view<Arguments, tbc::lt::a> words) noexcept;

      [[nodiscard]] bool empty() const noexcept;

      tbc::view<std::optional<std::string_view>, tbc::lt::a> next() noexcept;

      tbc::view<std::string_view, tbc::lt::a> take(const char* missing);

      [[nodiscard]] tbc::view<Arguments, tbc::lt::a> rest() const noexcept;

    private:
      tbc::view<Arguments, tbc::lt::a> words_;
    };

  }
}

// Interface: command_io.cppm
export {
  namespace telar::runtime::cli {

    std::string quoteJson(std::string_view text, JsonEscapes escapes = JsonEscapes::standard);

    void writeBytes(int descriptor, std::span<const Byte> bytes);

    void writeText(std::string_view text, int descriptor = STDOUT_FILENO);

    std::string_view textBytes(std::span<const Byte> bytes);

    std::uint64_t randomIdentity();

    const char* jsonBoolean(bool value);

    std::string_view commandErrorName(const std::exception& error);

  }
}

// Interface: command_limit.cppm
export {
  namespace telar::runtime::cli {

    std::string limitDescription(const LimitReach& reach, std::uint64_t hits = 1);

    void reportCommandLimit(const LimitReach& reach);

  }
}
