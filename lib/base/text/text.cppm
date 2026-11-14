module;
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/text/base64.hpp"
#include "telar_base/text/decimal.hpp"

export module telar.base.text;

import std;
import telar.tbc;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.sys.socket;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
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

// The program's name and version, as child processes and terminal queries see them.
export namespace telar::runtime::control {

  inline constexpr std::string_view program_name = "telar";
  inline constexpr std::string_view program_version = "dev";
  inline constexpr std::string_view terminfo_name = "xterm-256color";

}

// Interface: telar_base/text/ascii.cppm
export {
  namespace telar::runtime {

    inline constexpr char asciiLower(char value) noexcept {
      return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
    }

    // `text` with its ASCII capitals lowered.
    std::string asciiLowerCopy(std::string_view text);

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

export {
  namespace telar::runtime {

    // Whether two secrets of public length are equal, in time that depends on the length alone, so
    // how long a forged candidate takes to fail reveals nothing of the secret.
    bool constantTimeEqual(std::string_view left, std::string_view right) noexcept;

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

    // The fields of `text`, region `a`, between the occurrences of `delimiter`, region `b`.
    class TextFields {
    public:
      explicit TextFields(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<std::string_view, tbc::lt::b> delimiter) noexcept;

      tbc::view<std::optional<std::string_view>, tbc::lt::a> next() noexcept;

    private:
      tbc::view<std::string_view, tbc::lt::a> remaining_;
      tbc::view<std::string_view, tbc::lt::b> delimiter_;
      bool finished_ = false;
    };

    tbc::view<std::string_view, tbc::lt::a> trimText(tbc::view<std::string_view, tbc::lt::a> text, std::string_view characters) noexcept;

  }
}

// Interface: telar_base/text/hexadecimal.cppm
export {
  namespace telar::runtime {

    // Writes `bytes` as lowercase hexadecimal into the first 2 * bytes.size() characters of
    // `output`, which must hold them, and returns what it wrote.
    constexpr tbc::view<std::string_view, tbc::lt::a> encodeLowerHex(std::span<const std::uint8_t> bytes, tbc::view<std::span<char>, tbc::lt::a> output) noexcept {
      constexpr std::string_view digits = "0123456789abcdef";

      TELAR_ASSERT(output.size() >= 2 * bytes.size());
      for (std::size_t index = 0; index < bytes.size(); ++index) {
        output[2 * index] = digits[bytes[index] >> 4];
        output[2 * index + 1] = digits[bytes[index] & 15];
      }

      return {output.data(), 2 * bytes.size()};
    }

    // Built in text.cpp for the base allocators of telar.base.memory.allocators.
    template <Allocator Memory>
    void appendLowerHex(String<Memory>& output, std::span<const std::uint8_t> bytes);

    extern template void appendLowerHex<Memory>(String<Memory>& output, std::span<const std::uint8_t> bytes);
    extern template void appendLowerHex<ConcurrentMemory>(String<ConcurrentMemory>& output, std::span<const std::uint8_t> bytes);
    extern template void appendLowerHex<SystemAllocator>(String<SystemAllocator>& output, std::span<const std::uint8_t> bytes);
    extern template void appendLowerHex<BudgetAllocator<SystemAllocator>>(String<BudgetAllocator<SystemAllocator>>& output, std::span<const std::uint8_t> bytes);

    std::string lowerHex(std::span<const std::uint8_t> bytes);

  }
}

// Interface: telar_base/text/identifier.cppm
export {
  namespace telar::runtime {

    bool validIdentifier(std::string_view name) noexcept;

  }
}

// Interface: telar_base/text/schema_version.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class SchemaVersion {
    public:
      static bool isOne(Memory& memory, const JsonValue& value);

    private:
      explicit SchemaVersion(Memory& memory);

      bool parse(std::string_view text);
      void truncateHexFallback();
      bool readMantissa(std::string_view text, unsigned base, bool floating);

      String<Memory> digits_;
      std::int64_t integer_digits_ = 0;
    };

    // Instantiated in text.cpp for the type-erased allocators and for the compositions of base
    // allocators the tests still name.
    extern template class SchemaVersion<Memory>;
    extern template class SchemaVersion<ConcurrentMemory>;
    extern template class SchemaVersion<BudgetAllocator<SystemAllocator>>;
    extern template class SchemaVersion<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

  }
}

// Interface: telar_base/text/hostname.cppm
// A host name or address a proxy may reach or a rule may name, checked without resolving it.
export {
  namespace telar::runtime {

    class ProxyHostname {
    public:
      static constexpr std::size_t maximum_bytes = 253;

      static bool validPattern(std::string_view pattern) noexcept;
      static bool validTarget(std::string_view hostname) noexcept;
      static std::optional<in6_addr> ipv6(std::string_view host) noexcept;

    private:
      static bool validLabels(std::string_view pattern) noexcept;

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

      static std::optional<ProxyTarget> parse(std::string_view head) noexcept;
    };

  }
}
