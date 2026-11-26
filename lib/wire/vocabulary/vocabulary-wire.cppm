module;
#include "telar_wire/codecs/telar_annotations.hpp"

export module telar.wire.vocabulary:wire;

import std;
import telar.tbc;
import telar.base.ds;
import telar.base.text.utf8;
import telar.vocabulary;

export {
  namespace telar {

    template <std::size_t N>
    struct FixedString {
      ds::Array<char, N> value;

      constexpr FixedString(const char (&text)[N]) // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays,cppcoreguidelines-explicit-constructor,misc-explicit-constructor): a template argument converts a string literal, a C array, to it
          : value(ds::toArray(text)) {}
    };

    template <std::size_t N>
    FixedString(const char (&text)[N]) -> FixedString<N>; // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): a string literal is a C array

    static_assert(std::same_as<Byte, unsigned char>);

    // The same bytes as text and as wire bytes, for the field codecs below, which call them per
    // field and per byte.
    [[tbc::hot_path]] [[nodiscard]] inline std::span<const Byte> byteView(std::string_view text) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {reinterpret_cast<const Byte*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): Byte may alias char, and no cast-free view reads text as bytes
#pragma clang unsafe_buffer_usage end
    }

    [[tbc::hot_path]] [[nodiscard]] inline std::string_view textView(std::span<const Byte> bytes) noexcept {
      return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias Byte, and no cast-free view reads bytes as text
    }

    inline constexpr std::size_t max_payload_size = std::size_t{4} * 1024 * 1024;
    inline constexpr std::size_t frame_prefix_size = sizeof(std::uint32_t);

    // The printable ASCII bytes, between the control bytes and DEL.
    inline constexpr Byte first_printable_byte = 0x20;
    inline constexpr Byte last_printable_byte = 0x7e;
    inline constexpr Byte delete_byte = 0x7f;

    enum class Direction : std::uint8_t {
      client,
      server,
      either,
    };

#ifdef TELAR_DEBUG
    namespace debug {

      inline constexpr std::string_view hex_digits = "0123456789abcdef";
      inline constexpr unsigned nibble_bits = 4;
      inline constexpr unsigned low_nibble = 0x0f;

      // The two lowercase hexadecimal digits of `byte`, the high one first.
      constexpr ds::Array<char, 2> hexPair(Byte byte) noexcept {
        return {{hex_digits[static_cast<unsigned>(byte) >> nibble_bits], hex_digits[static_cast<unsigned>(byte) & low_nibble]}};
      }

      // `byte` as a C literal, 0xNN, terminated.
      constexpr ds::Array<char, sizeof("0x00")> byteLiteral(Byte byte) noexcept {
        const auto digits = hexPair(byte);

        return {{'0', 'x', digits[0], digits[1], '\0'}};
      }

      // The bytes between quotes, each one that is not printable as \xNN, and a terminating NUL.
      template <std::size_t N>
      using BytesText = ds::Array<char, (N * 4) + 3>;

      template <std::size_t N>
      [[tbc::generic]] BytesText<N> valueText(const ds::Array<Byte, N>& value) {
        BytesText<N> text{};
        std::size_t position = 0;

        text.atMut(position++) = '"';

        for (const auto byte : value) {
          if (byte >= first_printable_byte && byte <= last_printable_byte && byte != '"' && byte != '\\') {
            text.atMut(position++) = static_cast<char>(byte);
          } else {
            const auto digits = hexPair(byte);

            text.atMut(position++) = '\\';
            text.atMut(position++) = 'x';
            text.atMut(position++) = digits[0];
            text.atMut(position++) = digits[1];
          }
        }

        text.atMut(position++) = '"';
        text.atMut(position) = '\0';
        return text;
      }

      constexpr ds::Array<char, sizeof("false")> boolText(bool value) {
        ds::Array<char, sizeof("false")> text{};
        const std::string_view word = value ? "true" : "false";

        std::ranges::copy(word, text.viewMut().begin());
        return text;
      }

      // The decimal digits of the largest Value, and a terminating NUL.
      template <std::unsigned_integral Value>
      using IntegerText = ds::Array<char, std::numeric_limits<Value>::digits10 + 2>;

      template <std::unsigned_integral Value>
      [[tbc::generic]] IntegerText<Value> integerText(Value value) {
        IntegerText<Value> text{};
        const auto digits = text.viewMut().first(text.size() - 1);

        std::to_chars(std::to_address(digits.begin()), std::to_address(digits.end()), value);
        return text;
      }

      template <typename Value>
      [[tbc::generic]] auto valueText(Value value) {
        if constexpr (std::same_as<Value, bool>) {
          return boolText(value);
        } else if constexpr (std::is_enum_v<Value>) {
          return valueText(static_cast<std::underlying_type_t<Value>>(value));
        } else {
          static_assert(std::unsigned_integral<Value>, "Add a formatter for this field type");

          return integerText(value);
        }
      }

      std::size_t columnWidth(std::size_t byte_count, const char* name, const char* value);
      void printBytes(std::span<const Byte> bytes, const char* name, const char* value, std::FILE* output, bool more);
      void printText(const char* text, std::size_t width, std::FILE* output, const char* separator);
      void printLabel(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more);
      void printValue(std::size_t byte_count, const char* name, const char* value, std::FILE* output, bool more);

    } // namespace debug
#endif

    // The frame owns decoded string bytes. This separate caller-owned buffer
    // owns decoded list elements and must not overlap the frame or be reused
    // while a decoded value still references it.
    // Decoded values view the input frame and the caller's decode storage, both in region `a`.
    using DecodeInput = tbc::mut_a<std::span<const Byte>>;
    using DecodeFrame = tbc::val_a<std::span<const Byte>>;
    template <typename Value>
    using Decoded = tbc::val_a<Value>;

    struct DecodeStorage {
      tbc::val_a<std::span<Byte>> remaining;

      template <typename T>
      [[tbc::generic]] tbc::val_a<std::span<T>> allocate(std::size_t count) {
        static_assert(std::is_trivially_destructible_v<T>);

        if (count == 0) {
          return {};
        }

        if (count > remaining.size() / sizeof(T)) {
          throw EncodingError{"Decode storage is too small"};
        }

        const auto bytes = count * sizeof(T);
        void* pointer = remaining.data();
        auto available = remaining.size();
        if (std::align(alignof(T), bytes, pointer, available) == nullptr) {
          throw EncodingError{"Decode storage is too small after alignment"};
        }

        auto* elements = static_cast<T*>(pointer);
        auto* next = static_cast<Byte*>(pointer) + bytes;

        remaining = {next, available - bytes};
        for (std::size_t i = 0; i < count; ++i) {
          std::construct_at(elements + i);
        }

        return {elements, count};
      }
    };

    template <std::unsigned_integral T>
      requires(!std::same_as<T, bool>)
    struct [[tbc::generic]] LittleEndian {
      using value_type = T;

      static constexpr std::size_t width = sizeof(T);
      static constexpr std::size_t byte_bits = 8;

      static void encode(T value, TELAR_CHANGES std::span<Byte>& output) TELAR_THROWS(EncodingError) {
        if (output.size() < width) {
          throw EncodingError{"Output buffer too small\0"};
        }

        for (std::size_t i = 0; i < width; ++i) {
          output[i] = static_cast<Byte>(value >> (i * byte_bits));
        }

        output = output.subspan(width);
      }

      static T decode(TELAR_CHANGES std::span<const Byte>& input) TELAR_THROWS(EncodingError) {
        if (input.size() < width) {
          throw EncodingError{"Input buffer is too small\0"};
        }

        T result = 0;

        for (std::size_t i = 0; i < width; ++i) {
          const auto byte = static_cast<T>(input[i]);

          result |= byte << (i * byte_bits);
        }

        input = input.subspan(width);
        return result;
      }
    };

    using u8 = LittleEndian<std::uint8_t>;
    using u16 = LittleEndian<std::uint16_t>;
    using u32 = LittleEndian<std::uint32_t>;
    using u64 = LittleEndian<std::uint64_t>;

    template <std::size_t N>
    struct [[tbc::generic]] FixedBytes {
      using value_type = ds::Array<Byte, N>;
      static constexpr std::size_t width = N;

      static void encode(const ds::Array<Byte, N>& value, std::span<Byte>& output) TELAR_THROWS(EncodingError) {
        if (output.size() < width) {
          throw EncodingError{"Output buffer too small"};
        }

        for (std::size_t i = 0; i < width; ++i) {
          output[i] = value[i];
        }

        output = output.subspan(width);
      }

      static ds::Array<Byte, N> decode(std::span<const Byte>& input) TELAR_THROWS(EncodingError) {
        if (input.size() < width) {
          throw EncodingError{"Input buffer is too small"};
        }

        ds::Array<Byte, N> value{};

        for (std::size_t i = 0; i < width; ++i) {
          value.atMut(i) = input[i];
        }

        input = input.subspan(width);
        return value;
      }
    };

    struct BoolByte {
      using value_type = bool;
      static constexpr std::size_t width = u8::width;

      static void encode(bool value, std::span<Byte>& output) TELAR_THROWS(EncodingError);
      static bool decode(TELAR_CHANGES std::span<const Byte>& input) TELAR_THROWS(EncodingError);
    };

    template <typename WireCodec>
    struct CodecWidth {};

    template <typename WireCodec>
      requires requires { WireCodec::width; }
    struct CodecWidth<WireCodec> {
      static constexpr std::size_t width = WireCodec::width;
    };

    template <typename WireCodec>
    consteval std::size_t minimumWidth() {
      if constexpr (requires { WireCodec::min_width; }) {
        return WireCodec::min_width;
      } else {
        return WireCodec::width;
      }
    }

    constexpr std::size_t checkedWireSize(std::size_t first, std::size_t second) {
      if (first > max_payload_size || second > max_payload_size - first) {
        throw EncodingError{"Encoded body exceeds the frame limit"};
      }

      return first + second;
    }

    template <typename WireCodec, typename Value>
    [[tbc::generic]] std::size_t wireSize(const Value& value) {
      if constexpr (requires { WireCodec::encodedSize(value); }) {
        return WireCodec::encodedSize(value);
      } else {
        return WireCodec::width;
      }
    }

    template <typename WireCodec, typename Storage>
      requires requires(std::span<const Byte>& input, Storage& storage) { WireCodec::decode(input, storage); }
    [[tbc::generic]] Decoded<std::remove_cvref_t<decltype(WireCodec::decode(std::declval<std::span<const Byte>&>(), std::declval<Storage&>()))>> decodeValue(DecodeInput input, Storage& storage) {
      return WireCodec::decode(input, storage);
    }

    template <typename WireCodec, typename Storage>
    [[tbc::generic]] Decoded<std::remove_cvref_t<decltype(WireCodec::decode(std::declval<std::span<const Byte>&>()))>> decodeValue(DecodeInput input, Storage& /*storage*/) {
      return WireCodec::decode(input);
    }

  } // namespace telar
}
