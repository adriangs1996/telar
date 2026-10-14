#pragma once

#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <span>
#include <type_traits>

#ifdef TELAR_DEBUG
#include <cstdio>
#include <limits>
#endif

#define KILO_BYTES(x) x * 1024
#define MEGA_BYTES(x) KILO_BYTES(x) * 1024

#if defined(__clang__)
#define _throw(ExceptionType) __attribute__((annotate("throws:" #ExceptionType)))
#else
#define _throw(ExceptionType)
#endif

#define _changes

namespace telar {

  template <std::size_t N> struct FixedString {
    char value[N];

    constexpr FixedString(const char (&text)[N]) {
      for (std::size_t i = 0; i < N; ++i) {
        value[i] = text[i];
      }
    }
  };

  struct EncodingError final : std::exception {
    EncodingError(const char *message) : message{message} {}

    const char *what() const noexcept override { return message; }

  private:
    const char *message;
  };

  using Byte = std::uint8_t;

  inline constexpr std::size_t max_payload_size = MEGA_BYTES(4);
  inline constexpr std::size_t frame_prefix_size = sizeof(std::uint32_t);

  enum class Direction { client, server, either };

#ifdef TELAR_DEBUG
  namespace debug {

    template <std::size_t N> auto valueText(const std::array<Byte, N> &value) {
      std::array<char, N * 4 + 3> text{};
      std::size_t position = 0;
      text[position++] = '"';

      for (const auto byte : value) {
        if (byte >= 0x20 && byte <= 0x7e && byte != '"' && byte != '\\') {
          text[position++] = static_cast<char>(byte);
        } else {
          std::snprintf(text.data() + position, text.size() - position, "\\x%02x",
                        static_cast<unsigned>(byte));
          position += 4;
        }
      }

      text[position++] = '"';
      text[position] = '\0';
      return text;
    }

    template <typename Value> auto valueText(Value value) {
      if constexpr (std::same_as<Value, bool>) {
        std::array<char, sizeof("false")> text{};
        std::snprintf(text.data(), text.size(), "%s", value ? "true" : "false");
        return text;
      } else if constexpr (std::is_enum_v<Value>) {
        return valueText(static_cast<std::underlying_type_t<Value>>(value));
      } else {
        static_assert(std::unsigned_integral<Value>, "Add a formatter for this field type");

        std::array<char, std::numeric_limits<Value>::digits10 + 2> text{};
        std::snprintf(text.data(), text.size(), "%llu", static_cast<unsigned long long>(value));
        return text;
      }
    }

    inline std::size_t columnWidth(std::size_t byte_count, const char *name, const char *value) {
      const auto bytes_width = byte_count == 0 ? 0 : byte_count * 3 - 1;
      const auto name_width = std::strlen(name);
      const auto value_width = std::strlen(value);
      const auto width = bytes_width > name_width ? bytes_width : name_width;

      return width > value_width ? width : value_width;
    }

    inline void printBytes(std::span<const Byte> bytes, const char *name, const char *value,
                           std::FILE *output, bool more) {
      for (std::size_t i = 0; i < bytes.size(); ++i) {
        if (i != 0) {
          std::fputc(' ', output);
        }

        std::fprintf(output, "%02x", static_cast<unsigned>(bytes[i]));
      }

      if (more) {
        const auto bytes_width = bytes.empty() ? 0 : bytes.size() * 3 - 1;
        const auto padding = columnWidth(bytes.size(), name, value) - bytes_width;
        std::fprintf(output, "%*s | ", static_cast<int>(padding), "");
      }
    }

    inline void printText(const char *text, std::size_t width, std::FILE *output,
                          const char *separator) {
      std::fputs(text, output);

      if (separator[0] != '\0') {
        const auto padding = width - std::strlen(text);
        std::fprintf(output, "%*s%s", static_cast<int>(padding), "", separator);
      }
    }

    inline void printLabel(std::size_t byte_count, const char *name, const char *value,
                           std::FILE *output, bool more) {
      printText(name, columnWidth(byte_count, name, value), output, more ? "   " : "");
    }

    inline void printValue(std::size_t byte_count, const char *name, const char *value,
                           std::FILE *output, bool more) {
      printText(value, columnWidth(byte_count, name, value), output, more ? " | " : "");
    }

  } // namespace debug
#endif

  template <std::unsigned_integral T>
    requires(!std::same_as<T, bool>)
  struct LittleEndian {

    using value_type = T;

    static constexpr std::size_t width = sizeof(T);

    static void encode(T value, _changes std::span<Byte> &output) _throw(EncodingError) {
      if (output.size() < width) {
        throw EncodingError{"Output buffer too small\0"};
      }

      for (std::size_t i = 0; i < width; ++i) {
        output[i] = static_cast<Byte>(value >> (i * 8));
      }

      output = output.subspan(width);
    }

    static T decode(_changes std::span<const Byte> &input) _throw(EncodingError) {
      if (input.size() < width) {
        throw EncodingError{"Input buffer is too small\0"};
      }

      T result = 0;

      for (std::size_t i = 0; i < width; ++i) {
        const auto byte = static_cast<T>(input[i]);
        result |= byte << (i * 8);
      }

      input = input.subspan(width);
      return result;
    }
  };

  using u8 = LittleEndian<std::uint8_t>;
  using u16 = LittleEndian<std::uint16_t>;
  using u32 = LittleEndian<std::uint32_t>;
  using u64 = LittleEndian<std::uint64_t>;

  template <std::size_t N> struct FixedBytes {
    using value_type = std::array<Byte, N>;
    static constexpr std::size_t width = N;

    static void encode(const std::array<Byte, N> &value, std::span<Byte> &output)
        _throw(EncodingError) {
      if (output.size() < width) {
        throw EncodingError{"Output buffer too small"};
      }

      for (std::size_t i = 0; i < width; ++i) {
        output[i] = value[i];
      }

      output = output.subspan(width);
    }

    static std::array<Byte, N> decode(std::span<const Byte> &input) _throw(EncodingError) {
      if (input.size() < width) {
        throw EncodingError{"Input buffer is too small"};
      }

      std::array<Byte, N> value{};
      for (std::size_t i = 0; i < width; ++i) {
        value[i] = input[i];
      }

      input = input.subspan(width);
      return value;
    }
  };

  struct BoolByte {
    using value_type = bool;
    static constexpr std::size_t width = u8::width;

    static void encode(bool value, std::span<Byte> &output) _throw(EncodingError) {
      u8::encode(static_cast<Byte>(value), output);
    }

    static bool decode(_changes std::span<const Byte> &input) _throw(EncodingError) {
      const auto value = u8::decode(input);
      if (value > 1) {
        throw EncodingError{"Bool value decode must be 0 or 1\0"};
      }

      return value != 0;
    }
  };

  template <typename WireCodec> struct CodecWidth {};

  template <typename WireCodec>
    requires requires { WireCodec::width; }
  struct CodecWidth<WireCodec> {
    static constexpr std::size_t width = WireCodec::width;
  };

  template <typename WireCodec> consteval std::size_t minimumWidth() {
    if constexpr (requires { WireCodec::min_width; }) {
      return WireCodec::min_width;
    } else {
      return WireCodec::width;
    }
  }

  inline std::size_t checkedWireSize(std::size_t first, std::size_t second) {
    if (first > max_payload_size || second > max_payload_size - first) {
      throw EncodingError{"Encoded body exceeds the frame limit"};
    }

    return first + second;
  }

  template <typename WireCodec, typename Value> std::size_t wireSize(const Value &value) {
    if constexpr (requires { WireCodec::encodedSize(value); }) {
      return WireCodec::encodedSize(value);
    } else {
      return WireCodec::width;
    }
  }

  template <typename WireCodec, typename Storage>
  auto decodeValue(std::span<const Byte> &input, Storage &storage) {
    if constexpr (requires { WireCodec::decode(input, storage); }) {
      return WireCodec::decode(input, storage);
    } else {
      return WireCodec::decode(input);
    }
  }

} // namespace telar
