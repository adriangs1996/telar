export module telar.cli.command_limit;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.base.diagnostics;
import telar.base.text.json;
import telar.vocabulary;
import telar.cli.output;
import telar.base.ds;
import telar.base.memory.allocators;

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
    ds::Option<Integer> maybeUnsigned(std::string_view text) noexcept;

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
    extern template ds::Option<unsigned short> maybeUnsigned<unsigned short>(std::string_view text) noexcept;
    extern template unsigned short number<unsigned short>(std::string_view text, const char* error);
    extern template unsigned int parseUnsigned<unsigned int>(std::string_view text);
    extern template ds::Option<unsigned int> maybeUnsigned<unsigned int>(std::string_view text) noexcept;
    extern template unsigned int number<unsigned int>(std::string_view text, const char* error);
    extern template unsigned long parseUnsigned<unsigned long>(std::string_view text);
    extern template ds::Option<unsigned long> maybeUnsigned<unsigned long>(std::string_view text) noexcept;
    extern template unsigned long number<unsigned long>(std::string_view text, const char* error);
    extern template unsigned long long parseUnsigned<unsigned long long>(std::string_view text);
    extern template ds::Option<unsigned long long> maybeUnsigned<unsigned long long>(std::string_view text) noexcept;
    extern template unsigned long long number<unsigned long long>(std::string_view text, const char* error);

    extern template int signedNumber<int>(std::string_view text, const char* error);
    extern template long signedNumber<long>(std::string_view text, const char* error);
    extern template long long signedNumber<long long>(std::string_view text, const char* error);

    // A nonzero identity: tabs, panes, clients and workspaces start at 1.
    std::uint64_t positive(std::string_view text, const char* error);

    // The word among `names` that `text` is, as the enum value at its position. The
    // implementation unit instantiates it for the protocol enums that commands parse.
    template <typename Enum, std::size_t Size>
    Enum choice(std::string_view text, const char* error, const ds::Array<std::string_view, Size>& names);

    // Consumes words left to right; `take` keeps each command's own missing-value
    // error.
    // Walks a command's words, region `a`; the words it hands out view them.
    class Cursor {
    public:
      explicit Cursor(tbc::view<Arguments, tbc::lt::a> words) noexcept;

      [[nodiscard]] bool empty() const noexcept;

      tbc::view<ds::Option<std::string_view>, tbc::lt::a> next() noexcept;

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

    // The text a command builds, in the allocator the command runs with.
    using Text = ds::String<Memory>;

    // Text whose control bytes print as escapes (\n, \r, \t, \xNN) where it is formatted, so a
    // field of a terminal line cannot move the cursor or break the line.
    struct EscapedField {
      std::string_view text;
    };

    // A number, or JSON's `null` without one, where it is formatted.
    template <typename Number>
    struct NumberOrNull {
      ds::Option<Number> value;
    };

    template <typename Number>
    constexpr NumberOrNull<Number> orNull(const ds::Option<Number>& value) noexcept {
      return {value};
    }

    // The text as a JSON string literal where it is formatted.
    constexpr JsonQuoted quoteJson(std::string_view text, JsonEscapes escapes = JsonEscapes::standard) noexcept {
      return {text, escapes};
    }

    void writeBytes(int descriptor, std::span<const Byte> bytes);

    void writeText(std::string_view text, int descriptor = STDOUT_FILENO);

    // Formats text to a descriptor through a buffer on the stack, written out as it fills and at
    // `flush`: nothing is allocated and the text has no limit on its length.
    class DescriptorWriter {
    public:
      explicit DescriptorWriter(int descriptor) noexcept
          : descriptor_(descriptor) {}

      DescriptorWriter(const DescriptorWriter&) = delete;
      DescriptorWriter& operator=(const DescriptorWriter&) = delete;

      template <typename... Arguments>
      void print(std::format_string<Arguments...> format, Arguments&&... arguments) {
        std::format_to(Appender{this}, format, std::forward<Arguments>(arguments)...);
      }

      void flush() {
        if (used_ != 0) {
          const auto used = std::exchange(used_, 0);

          writeText({buffer_.data(), used}, descriptor_);
        }
      }

    private:
      struct Appender {
        using difference_type = std::ptrdiff_t;

        DescriptorWriter* writer;

        Appender& operator=(char character) {
          writer->push(character);
          return *this;
        }

        Appender& operator*() noexcept {
          return *this;
        }

        Appender& operator++() noexcept {
          return *this;
        }

        Appender operator++(int) noexcept {
          return *this;
        }
      };

      void push(char character) {
        if (used_ == buffer_.size()) {
          flush();
        }

        buffer_.atMut(used_++) = character;
      }

      ds::Array<char, 4096> buffer_;
      std::size_t used_ = 0;
      int descriptor_;
    };

    // Writes the formatted text to `descriptor`, as one write when it fits the writer's buffer.
    template <typename... Arguments>
    void writeFormatted(int descriptor, std::format_string<Arguments...> format, Arguments&&... arguments) {
      DescriptorWriter writer{descriptor};

      writer.print(format, std::forward<Arguments>(arguments)...);
      writer.flush();
    }

    std::string_view textBytes(std::span<const Byte> bytes);

    std::uint64_t randomIdentity();

    const char* jsonBoolean(bool value);

    std::string_view commandErrorName(const std::exception& error);

  }
}

// Interface: command_limit.cppm
export {
  namespace telar::runtime::cli {

    // How a limit was reached, as `name: requested noun; limit value`, where it is formatted.
    struct LimitDescription {
      const LimitReach& reach;
      std::uint64_t hits = 1;
    };

    constexpr LimitDescription limitDescription(const LimitReach& reach, std::uint64_t hits = 1) noexcept {
      return {reach, hits};
    }

    void reportCommandLimit(const LimitReach& reach);

  }
}

template <>
struct std::formatter<telar::runtime::cli::EscapedField, char> {
  constexpr tbc::view<std::format_parse_context::iterator, tbc::lt::a> parse(tbc::view<std::format_parse_context&, tbc::lt::a> context) {
    return context.begin();
  }

  template <typename Context>
  tbc::view<typename Context::iterator, tbc::lt::a> format(const telar::runtime::cli::EscapedField& field, tbc::view<Context&, tbc::lt::a> context) const {
    auto output = context.out();

    for (const unsigned char byte : field.text) {
      switch (byte) {
      case '\n':
        output = std::format_to(output, "\\n");
        break;
      case '\r':
        output = std::format_to(output, "\\r");
        break;
      case '\t':
        output = std::format_to(output, "\\t");
        break;
      default:
        if (byte < 0x20 || byte == 0x7f) {
          output = std::format_to(output, "\\x{:02x}", byte);
        } else {
          *output++ = static_cast<char>(byte);
        }
      }
    }

    return output;
  }
};

template <typename Number>
struct std::formatter<telar::runtime::cli::NumberOrNull<Number>, char> {
  constexpr tbc::view<std::format_parse_context::iterator, tbc::lt::a> parse(tbc::view<std::format_parse_context&, tbc::lt::a> context) {
    return context.begin();
  }

  template <typename Context>
  tbc::view<typename Context::iterator, tbc::lt::a> format(const telar::runtime::cli::NumberOrNull<Number>& number, tbc::view<Context&, tbc::lt::a> context) const {
    return number.value ? std::format_to(context.out(), "{}", *number.value) : std::format_to(context.out(), "null");
  }
};

template <>
struct std::formatter<telar::runtime::cli::LimitDescription, char> {
  constexpr tbc::view<std::format_parse_context::iterator, tbc::lt::a> parse(tbc::view<std::format_parse_context&, tbc::lt::a> context) {
    return context.begin();
  }

  template <typename Context>
  tbc::view<typename Context::iterator, tbc::lt::a> format(const telar::runtime::cli::LimitDescription& description, tbc::view<Context&, tbc::lt::a> context) const {
    const auto& reach = description.reach;
    auto output = std::format_to(context.out(), "{}: ", reach.name);
    const std::string_view space = reach.noun.empty() ? "" : " ";

    if (reach.requested) {
      output = std::format_to(output, "{}{}{}; limit {}", *reach.requested, space, reach.noun, reach.value);
    } else if (reach.value == 0) {
      output = std::format_to(output, "limit reached");
    } else {
      output = std::format_to(output, "limit {}{}{} reached", reach.value, space, reach.noun);
    }

    if (description.hits > 1) {
      output = std::format_to(output, " ({} times)", description.hits);
    }

    return output;
  }
};

export {
  namespace telar::runtime::cli {

  }
}
