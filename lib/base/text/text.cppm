module;
#include "tbc/view.hpp"
#include "telar_base/program_identity.hpp"
#include "telar_base/text/base64.hpp"
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include <string_view>

#include <concepts>
#include <limits>
#include <optional>

#include <initializer_list>

#include <cstdint>
#include <span>

#include <algorithm>

#include <array>
#include <cassert>

#include <arpa/inet.h>
#include <netinet/in.h>

#include "telar_base/text/constant_time.hpp"
#include "telar_base/text/decimal.hpp"

export module telar.base.text;

import telar.base.diagnostics;
import telar.base.memory.allocators;

// Aggregates JSON and UTF-8 while importers move to the module they use.
export import telar.base.text.json;
export import telar.base.text.utf8;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
  using telar::runtime::constantTimeEqual;
  using telar::runtime::NumberError;
  using telar::runtime::parseExact;
  using telar::runtime::unsignedDecimal;
  using telar::runtime::unsignedNumber;
}

export namespace telar::runtime::base64 {
  using telar::runtime::base64::alphabet;
  using telar::runtime::base64::decode;
  using telar::runtime::base64::encode;
  using telar::runtime::base64::encoded_pairs;
  using telar::runtime::base64::Padding;
}

export namespace telar::runtime::control {
  using telar::runtime::control::program_name;
  using telar::runtime::control::program_version;
  using telar::runtime::control::terminfo_name;
}

// Interface: telar_base/text/ascii.cppm
export {
  namespace telar::runtime {

    inline constexpr char asciiLower(char value) noexcept {
      return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
    }

    // `text` with its ASCII capitals lowered.
    inline std::string asciiLowerCopy(std::string_view text) {
      std::string result{text};

      for (auto& byte : result) {
        byte = asciiLower(byte);
      }

      return result;
    }

    inline constexpr bool asciiEqualIgnoreCase(std::string_view left, std::string_view right) noexcept {
      if (left.size() != right.size()) {
        return false;
      }

      for (std::size_t index = 0; index < left.size(); ++index) {
        if (asciiLower(left[index]) != asciiLower(right[index])) {
          return false;
        }
      }

      return true;
    }

  }
}

// Interface: telar_base/text/fnv.cppm
export {
  namespace telar::runtime {

    inline constexpr std::uint64_t fnv1a64_basis = 0xcbf29ce484222325;
    inline constexpr std::uint64_t fnv1a64_prime = 0x100000001b3;

    // 64-bit FNV-1a over `bytes`, continuing `hash` to cover several pieces as one.
    constexpr std::uint64_t fnv1a64(std::string_view bytes, std::uint64_t hash = fnv1a64_basis) noexcept {
      for (const auto byte : bytes) {
        hash = (hash ^ static_cast<unsigned char>(byte)) * fnv1a64_prime;
      }

      return hash;
    }

  }
}

// Interface: telar_base/text/bracketed_paste.cppm
export {
  namespace telar {

    // A paste as a program that enabled bracketed paste (mode 2004) reads it: the text between
    // the frame's start and end. A terminator inside the text would close the frame early and
    // let its tail run as typed input, so its ESC becomes a space, as ghostty's paste encoder
    // does. The encoded paste has as many bytes as the text plus the frame.
    struct BracketedPaste {
      static constexpr std::string_view begin = "\x1b[200~";
      static constexpr std::string_view end = "\x1b[201~";
      static constexpr std::size_t framing_bytes = begin.size() + end.size();

      [[nodiscard]] static constexpr std::size_t size(std::size_t text, bool bracketed) noexcept {
        return text + (bracketed ? framing_bytes : 0);
      }

      // Hands `sink` the text inside a frame in order, in runs between its neutralized terminators.
      // Pieces given one after another must not split a terminator between them.
      template <typename Sink>
      static constexpr void body(std::string_view text, Sink&& sink) {
        for (auto found = text.find(end); found != std::string_view::npos; found = text.find(end)) {
          if (found != 0) {
            sink(text.substr(0, found));
          }

          sink(std::string_view{" "});
          text.remove_prefix(found + 1);
        }

        if (!text.empty()) {
          sink(text);
        }
      }

      // Hands `sink` the paste of `text`, framed when `bracketed`, without copying it.
      template <typename Sink>
      static constexpr void encode(std::string_view text, bool bracketed, Sink&& sink) {
        if (!bracketed) {
          if (!text.empty()) {
            sink(text);
          }

          return;
        }

        sink(begin);
        body(text, sink);
        sink(end);
      }
    };

  }
}

// Interface: telar_base/text/executable_name.cppm
export {
  namespace telar::runtime {

    inline constexpr std::string_view withoutExecutableSuffix(std::string_view name) noexcept {
      for (const auto suffix : {std::string_view{".exe"}, std::string_view{".cmd"}, std::string_view{".bat"}, std::string_view{".js"}}) {
        if (name.size() >= suffix.size() && asciiEqualIgnoreCase(name.substr(name.size() - suffix.size()), suffix)) {
          return name.substr(0, name.size() - suffix.size());
        }
      }

      return name;
    }

  }
}

// Interface: telar_base/text/fields.cppm
export {
  namespace telar::runtime {

    class TextFields {
    public:
      inline explicit TextFields(std::string_view text, std::string_view delimiter) noexcept
          : remaining_(text),
            delimiter_(delimiter) {}

      inline std::optional<std::string_view> next() noexcept {
        if (finished_) {
          return std::nullopt;
        }

        const auto boundary = remaining_.find(delimiter_);
        const auto field = remaining_.substr(0, boundary);

        if (boundary == std::string_view::npos) {
          finished_ = true;
        } else {
          remaining_.remove_prefix(boundary + delimiter_.size());
        }

        return field;
      }

    private:
      std::string_view remaining_;
      std::string_view delimiter_;
      bool finished_ = false;
    };

    inline tbc::view<std::string_view, tbc::lt::a> trimText(tbc::view<std::string_view, tbc::lt::a> text, std::string_view characters) noexcept {
      const auto start = text.find_first_not_of(characters);
      if (start == std::string_view::npos) {
        return {};
      }

      return text.substr(start, text.find_last_not_of(characters) - start + 1);
    }

  }
}

// Interface: telar_base/text/hexadecimal.cppm
export {
  namespace telar::runtime {

    // Writes `bytes` as lowercase hexadecimal into the first 2 * bytes.size() characters of
    // `output`, which must hold them, and returns what it wrote.
    constexpr tbc::view<std::string_view, tbc::lt::a> encodeLowerHex(std::span<const std::uint8_t> bytes, tbc::view<std::span<char>, tbc::lt::a> output) noexcept {
      constexpr std::string_view digits = "0123456789abcdef";

      assert(output.size() >= 2 * bytes.size());
      for (std::size_t index = 0; index < bytes.size(); ++index) {
        output[2 * index] = digits[bytes[index] >> 4];
        output[2 * index + 1] = digits[bytes[index] & 15];
      }

      return {output.data(), 2 * bytes.size()};
    }

    template <Allocator Memory>
    void appendLowerHex(String<Memory>& output, std::span<const std::uint8_t> bytes) {
      const auto start = output.size();

      output.resize(start + 2 * bytes.size());
      static_cast<void>(encodeLowerHex(bytes, std::span{output}.subspan(start)));
    }

    inline std::string lowerHex(std::span<const std::uint8_t> bytes) {
      std::string text(2 * bytes.size(), '\0');

      static_cast<void>(encodeLowerHex(bytes, text));
      return text;
    }

  }
}

// Interface: telar_base/text/identifier.cppm
export {
  namespace telar::runtime {

    inline bool validIdentifier(std::string_view name) noexcept {
      if (name.empty() || name.front() == '.' || name.back() == '.' || name.contains("..")) {
        return false;
      }

      return std::ranges::all_of(name, [](unsigned char byte) {
        return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '-' || byte == '_';
      });
    }

  }
}

// Interface: telar_base/text/schema_version.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class SchemaVersion {
    public:
      inline static bool isOne(Memory& memory, const JsonValue& value) {
        String<Memory> text{AllocatorRef<char, Memory>{memory}};

        if (value.encoded().starts_with('"')) {
          value.string(text);
        } else {
          text = value.encoded();
        }

        return SchemaVersion{memory}.parse(text);
      }

    private:
      inline explicit SchemaVersion(Memory& memory)
          : digits_(AllocatorRef<char, Memory>{memory}) {}

      inline bool parse(std::string_view text) {
        const bool floating = text.find_first_of(".eE") != std::string_view::npos;

        if (text.starts_with('+')) {
          text.remove_prefix(1);
        }

        if (text.empty() || text.starts_with('-') || text.front() == '_' || text.back() == '_') {
          return false;
        }

        const bool hexadecimal = floating && (text.starts_with("0x") || text.starts_with("0X"));
        if (hexadecimal) {
          text.remove_prefix(2);
        }

        const unsigned base = hexadecimal ? 16 : 10;
        const auto exponent_at = text.find_first_of(hexadecimal ? "pP" : "eE");
        const auto mantissa = text.substr(0, exponent_at);
        if (!readMantissa(mantissa, base, floating)) {
          return false;
        }

        std::int64_t exponent = 0;
        if (exponent_at != std::string_view::npos && (!floating || !readExponent(text.substr(exponent_at + 1), exponent))) {
          return false;
        }

        const auto first = digits_.find_first_not_of('0');
        if (first == String<Memory>::npos) {
          return false;
        }

        exponent += integer_digits_ - static_cast<std::int64_t>(first);
        if (hexadecimal && (digits_.size() - (first / 4) * 4) / 4 > 32) {
          truncateHexFallback();
        }

        const auto significant = std::string_view{digits_}.substr(first);

        if (!floating) {
          return exponent == 1 && compare(significant, "1") == 0;
        }

        // Versions are compared as binary128 values: this is their exact rounding
        // interval around one; double precision would accept different versions.
        const auto lower = hexadecimal ? std::string_view{binary_lower.data(), binary_lower.size()} : decimal_lower;
        const auto upper = hexadecimal ? std::string_view{binary_upper.data(), binary_upper.size()} : decimal_upper;

        if (exponent == 0) {
          return compare(significant, lower) >= 0;
        }

        return exponent == 1 && compare(significant, upper) <= 0;
      }

      inline void truncateHexFallback() {
        // The reference's long-hex fallback stops at a decimal coefficient of
        // 10^31, so its discarded tail cannot participate in binary128 rounding.
        __uint128_t coefficient = 0;
        std::size_t consumed = 0;

        while (consumed < digits_.size() && coefficient < hex_fallback_coefficient) {
          for (unsigned bit = 0; bit < 4; ++bit) {
            coefficient = coefficient * 2 + static_cast<unsigned>(digits_[consumed++] - '0');
          }
        }

        digits_.resize(consumed);
      }

      inline bool readMantissa(std::string_view text, unsigned base, bool floating) {
        bool point = false;

        for (std::size_t index = 0; index < text.size(); ++index) {
          const char byte = text[index];
          if (byte == '_') {
            if (index == 0 || index + 1 == text.size() || (floating && (digit(text[index - 1]) >= base || digit(text[index + 1]) >= base))) {
              return false;
            }

            continue;
          }

          if (byte == '.' && floating && !point) {
            point = true;
            continue;
          }

          const auto value = digit(byte);
          if (value >= base) {
            return false;
          }

          if (base == 16) {
            for (unsigned shift = 4; shift != 0; --shift) {
              digits_ += static_cast<char>('0' + ((value >> (shift - 1)) & 1));
            }
          } else {
            digits_ += byte;
          }

          if (!point) {
            integer_digits_ += base == 16 ? 4 : 1;
          }
        }

        return !digits_.empty();
      }

      inline static bool readExponent(std::string_view text, std::int64_t& value) noexcept {
        const bool negative = text.starts_with('-');
        if (negative || text.starts_with('+')) {
          text.remove_prefix(1);
        }

        if (text.empty()) {
          return false;
        }

        for (std::size_t index = 0; index < text.size(); ++index) {
          if (text[index] == '_') {
            if (index == 0 || index + 1 == text.size() || digit(text[index - 1]) >= 10 || digit(text[index + 1]) >= 10) {
              return false;
            }

            continue;
          }

          const auto number = digit(text[index]);
          if (number >= 10) {
            return false;
          }

          value = std::min(exponent_limit, value * 10 + number);
        }

        value = negative ? -value : value;
        return true;
      }

      inline static unsigned digit(char byte) noexcept {
        if (byte >= '0' && byte <= '9') {
          return static_cast<unsigned>(byte - '0');
        }

        if (byte >= 'a' && byte <= 'f') {
          return static_cast<unsigned>(byte - 'a' + 10);
        }

        if (byte >= 'A' && byte <= 'F') {
          return static_cast<unsigned>(byte - 'A' + 10);
        }

        return 16;
      }

      inline static int compare(std::string_view left, std::string_view right) noexcept {
        for (std::size_t index = 0; index < std::max(left.size(), right.size()); ++index) {
          const auto first = index < left.size() ? left[index] : '0';
          const auto second = index < right.size() ? right[index] : '0';
          if (first != second) {
            return first < second ? -1 : 1;
          }
        }

        return 0;
      }

      static constexpr std::int64_t exponent_limit = 1'000'000;
      static constexpr auto hex_fallback_coefficient = [] {
        __uint128_t value = 1;

        for (unsigned power = 0; power < 31; ++power) {
          value *= 10;
        }

        return value;
      }();
      static constexpr std::string_view decimal_lower = "999999999999999999999999999999999951851751390319103673600551435376817036547458794615295119001530110836029052734375";
      static constexpr std::string_view decimal_upper = "100000000000000000000000000000000009629649721936179265279889712924636592690508241076940976199693977832794189453125";
      static constexpr auto binary_lower = [] {
        std::array<char, 114> digits;

        digits.fill('1');
        return digits;
      }();
      static constexpr auto binary_upper = [] {
        std::array<char, 114> digits;

        digits.fill('0');
        digits.front() = '1';
        digits.back() = '1';
        return digits;
      }();
      String<Memory> digits_;
      std::int64_t integer_digits_ = 0;
    };

  }
}

// Interface: telar_base/text/hostname.cppm
// A host name or address a proxy may reach or a rule may name, checked without resolving it.
export {
  namespace telar::runtime {

    class ProxyHostname {
    public:
      static constexpr std::size_t maximum_bytes = 253;

      inline static bool validPattern(std::string_view pattern) noexcept {
        if (pattern.empty() || pattern.size() > maximum_bytes) {
          return false;
        }

        if (pattern.contains(':')) {
          return ipv6(pattern).has_value();
        }

        if (pattern == "*") {
          return true;
        }

        if (pattern.starts_with("*.")) {
          pattern.remove_prefix(2);
        }

        return validLabels(pattern);
      }

      inline static bool validTarget(std::string_view hostname) noexcept {
        if (hostname.empty() || hostname.size() > maximum_bytes) {
          return false;
        }

        if (hostname.contains(':')) {
          return ipv6(hostname).has_value();
        }

        if (hostname.ends_with('.')) {
          hostname.remove_suffix(1);
        }

        return validLabels(hostname);
      }

      inline static std::optional<in6_addr> ipv6(std::string_view host) noexcept {
        if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
          return {};
        }

        std::array<char, INET6_ADDRSTRLEN> text{};

        std::ranges::copy(host, text.begin());
        in6_addr address{};

        return ::inet_pton(AF_INET6, text.data(), &address) == 1 ? std::optional{address} : std::nullopt;
      }

    private:
      inline static bool validLabels(std::string_view pattern) noexcept {
        std::size_t label_length = 0;
        char previous = '\0';

        for (const char byte : pattern) {
          if (byte == '.') {
            if (label_length == 0 || label_length > maximum_label_bytes || previous == '-') {
              return false;
            }

            label_length = 0;
          } else if (byte == '-') {
            if (label_length == 0) {
              return false;
            }

            ++label_length;
          } else {
            const char lower = asciiLower(byte);
            if ((lower < 'a' || lower > 'z') && (byte < '0' || byte > '9')) {
              return false;
            }

            ++label_length;
          }

          previous = byte;
        }

        return label_length != 0 && label_length <= maximum_label_bytes && previous != '-';
      }

      static constexpr std::size_t maximum_label_bytes = 63;
    };

  }
}

// Interface: proxy/target.cppm
export {
  namespace telar::runtime {

    struct ProxyTarget {
      std::string_view hostname;
      std::uint16_t port;

      inline static std::optional<ProxyTarget> parse(std::string_view head) noexcept {
        constexpr std::string_view method = "CONNECT ";
        constexpr std::string_view version = " HTTP/1.1";
        const auto line_end = head.find("\r\n");
        if (line_end == std::string_view::npos) {
          return std::nullopt;
        }

        const auto line = head.substr(0, line_end);
        if (!line.starts_with(method) || !line.ends_with(version) || line.size() <= method.size() + version.size()) {
          return std::nullopt;
        }

        const auto authority = line.substr(method.size(), line.size() - method.size() - version.size());
        const auto colon = authority.rfind(':');
        if (colon == std::string_view::npos || colon == 0 || colon > ProxyHostname::maximum_bytes) {
          return std::nullopt;
        }

        const auto hostname = authority.substr(0, colon);
        if (!ProxyHostname::validTarget(hostname)) {
          return std::nullopt;
        }

        const auto port_text = authority.substr(colon + 1);
        const auto port = parseExact<std::uint16_t>(port_text).value_or(0);
        if (port == 0) {
          return std::nullopt;
        }

        return ProxyTarget{hostname, port};
      }
    };

  }
}
