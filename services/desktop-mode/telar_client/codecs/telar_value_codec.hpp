#pragma once

#include "telar_codec.hpp"

#include <bit>
#include <limits>
#include <memory>
#include <optional>
#include <string_view>

namespace telar {

  // The frame owns decoded string bytes. This separate caller-owned buffer
  // owns decoded list elements and must not overlap the frame or be reused
  // while a decoded value still references it.
  struct DecodeStorage {
    std::span<Byte> remaining{};

    template <typename T> std::span<T> allocate(std::size_t count) {
      static_assert(std::is_trivially_destructible_v<T>);

      if (count == 0) {
        return {};
      }
      if (count > remaining.size() / sizeof(T)) {
        throw EncodingError{"Decode storage is too small"};
      }

      const auto bytes = count * sizeof(T);
      void *pointer = remaining.data();
      auto available = remaining.size();
      if (std::align(alignof(T), bytes, pointer, available) == nullptr) {
        throw EncodingError{"Decode storage is too small after alignment"};
      }

      auto *elements = static_cast<T *>(pointer);
      auto *next = static_cast<Byte *>(pointer) + bytes;
      remaining = {next, available - bytes};
      for (std::size_t i = 0; i < count; ++i) {
        std::construct_at(elements + i);
      }

      return {elements, count};
    }
  };

  template <std::signed_integral T> struct SignedLittleEndian {
    using value_type = T;
    using Unsigned = std::make_unsigned_t<T>;
    static constexpr std::size_t width = sizeof(T);

    static void encode(T value, std::span<Byte> &output) {
      LittleEndian<Unsigned>::encode(std::bit_cast<Unsigned>(value), output);
    }

    static T decode(std::span<const Byte> &input) {
      return std::bit_cast<T>(LittleEndian<Unsigned>::decode(input));
    }
  };

  using i32 = SignedLittleEndian<std::int32_t>;
  using i64 = SignedLittleEndian<std::int64_t>;

  template <typename IntegerCodec, typename IntegerCodec::value_type Minimum,
            typename IntegerCodec::value_type Maximum = std::numeric_limits<typename IntegerCodec::value_type>::max()>
  struct BoundedInteger : CodecWidth<IntegerCodec> {
    using value_type = typename IntegerCodec::value_type;

    static value_type validate(value_type value) {
      if (value < Minimum || value > Maximum) {
        throw EncodingError{"Integer outside its wire range"};
      }

      return value;
    }

    static void encode(value_type value, std::span<Byte> &output) {
      IntegerCodec::encode(validate(value), output);
    }

    static value_type decode(std::span<const Byte> &input) {
      return validate(IntegerCodec::decode(input));
    }
  };

  using NonzeroU64 = BoundedInteger<u64, 1>;

  template <typename Enum, Byte Maximum, Byte Minimum = 0> struct EnumByte {
    using value_type = Enum;
    static_assert(std::is_same_v<std::underlying_type_t<Enum>, Byte>);
    static constexpr std::size_t width = 1;

    static Enum validate(Enum value) {
      const auto raw = static_cast<Byte>(value);
      if (raw < Minimum || raw > Maximum) {
        throw EncodingError{"Unknown enum value"};
      }

      return value;
    }

    static void encode(Enum value, std::span<Byte> &output) {
      u8::encode(static_cast<Byte>(validate(value)), output);
    }

    static Enum decode(std::span<const Byte> &input) {
      return validate(static_cast<Enum>(u8::decode(input)));
    }
  };

  template <typename Enum, Enum... Allowed> struct EnumChoiceByte {
    using value_type = Enum;
    static_assert(std::is_same_v<std::underlying_type_t<Enum>, Byte>);
    static constexpr std::size_t width = 1;

    static Enum validate(Enum value) {
      if (!((value == Allowed) || ...)) {
        throw EncodingError{"Unknown enum value"};
      }

      return value;
    }

    static void encode(Enum value, std::span<Byte> &output) {
      u8::encode(static_cast<Byte>(validate(value)), output);
    }

    static Enum decode(std::span<const Byte> &input) {
      return validate(static_cast<Enum>(u8::decode(input)));
    }
  };

  enum class TextRule { bytes, utf8, display, multiline };

  inline void validateUtf8(std::string_view value) {
    std::size_t index = 0;
    while (index < value.size()) {
      const auto lead = static_cast<Byte>(value[index]);
      if (lead < 0x80) {
        ++index;
        continue;
      }

      const std::size_t length = lead >= 0xc2 && lead <= 0xdf ? 2 :
                                 lead >= 0xe0 && lead <= 0xef ? 3 :
                                 lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
      if (length == 0 || length > value.size() - index) {
        throw EncodingError{"Invalid UTF-8"};
      }

      for (std::size_t i = 1; i < length; ++i) {
        const auto byte = static_cast<Byte>(value[index + i]);
        if (byte < 0x80 || byte > 0xbf) {
          throw EncodingError{"Invalid UTF-8 continuation"};
        }
      }
      const auto second = static_cast<Byte>(value[index + 1]);
      if ((lead == 0xe0 && second < 0xa0) || (lead == 0xed && second >= 0xa0) ||
          (lead == 0xf0 && second < 0x90) || (lead == 0xf4 && second > 0x8f)) {
        throw EncodingError{"Invalid UTF-8 scalar"};
      }
      index += length;
    }
  }

  template <typename LengthCodec, std::size_t Maximum, bool EmptyAllowed = true, TextRule Rule = TextRule::bytes>
  struct SizedText {
    using value_type = std::string_view;
    static constexpr std::size_t min_width = LengthCodec::width;
    static_assert(Maximum <= std::numeric_limits<typename LengthCodec::value_type>::max());

    static void validate(std::string_view value) {
      if (value.size() > Maximum || (!EmptyAllowed && value.empty())) {
        throw EncodingError{"Invalid sized text"};
      }

      if constexpr (Rule != TextRule::utf8) {
        if (value.find('\0') != std::string_view::npos) {
          throw EncodingError{"Embedded NUL in text"};
        }
      }
      if constexpr (Rule != TextRule::bytes) {
        validateUtf8(value);
      }
      if constexpr (Rule == TextRule::display || Rule == TextRule::multiline) {
        for (const auto character : value) {
          const auto byte = static_cast<Byte>(character);
          const auto allowed = Rule == TextRule::multiline && (byte == '\n' || byte == '\t');
          if ((byte < 0x20 && !allowed) || byte == 0x7f) {
            throw EncodingError{"Control byte in display text"};
          }
        }
      }
    }

    static std::size_t encodedSize(std::string_view value) {
      validate(value);

      return checkedWireSize(LengthCodec::width, value.size());
    }

    static void encode(std::string_view value, std::span<Byte> &output) {
      if (output.size() < encodedSize(value)) {
        throw EncodingError{"Output buffer too small"};
      }

      LengthCodec::encode(static_cast<typename LengthCodec::value_type>(value.size()), output);
      if (!value.empty()) {
        std::memcpy(output.data(), value.data(), value.size());
      }
      output = output.subspan(value.size());
    }

    static std::string_view decode(std::span<const Byte> &input) {
      const auto length = LengthCodec::decode(input);
      if (length > Maximum || length > input.size()) {
        throw EncodingError{"Invalid sized text length"};
      }

      const std::string_view value{reinterpret_cast<const char *>(input.data()), length};
      validate(value);
      input = input.subspan(length);

      return value;
    }
  };

  template <std::size_t Maximum, bool EmptyAllowed = true>
  using Text16 = SizedText<u16, Maximum, EmptyAllowed>;

  template <std::size_t Maximum, bool EmptyAllowed = true>
  using Text32 = SizedText<u32, Maximum, EmptyAllowed>;

  template <std::size_t Maximum, bool EmptyAllowed = true>
  using DisplayText16 = SizedText<u16, Maximum, EmptyAllowed, TextRule::display>;

  template <std::size_t Maximum>
  using MessageText16 = SizedText<u16, Maximum, true, TextRule::multiline>;

  template <std::size_t Maximum>
  using Utf8Text16 = SizedText<u16, Maximum, true, TextRule::utf8>;

  template <typename ValueCodec> struct OptionalValue {
    using value_type = std::optional<typename ValueCodec::value_type>;
    static constexpr std::size_t min_width = 1;

    static std::size_t encodedSize(const value_type &value) {
      return value ? checkedWireSize(1, wireSize<ValueCodec>(*value)) : 1;
    }

    static void encode(const value_type &value, std::span<Byte> &output) {
      if (output.size() < encodedSize(value)) {
        throw EncodingError{"Output buffer too small"};
      }

      BoolByte::encode(value.has_value(), output);
      if (value) {
        ValueCodec::encode(*value, output);
      }
    }

    static value_type decode(std::span<const Byte> &input, DecodeStorage &storage) {
      if (!BoolByte::decode(input)) {
        return std::nullopt;
      }

      return decodeValue<ValueCodec>(input, storage);
    }
  };

  template <typename CountCodec, typename ElementCodec, std::size_t Maximum, std::size_t Minimum = 0>
  struct CountedSpan {
    using Element = typename ElementCodec::value_type;
    using value_type = std::span<const Element>;
    static constexpr std::size_t min_width = CountCodec::width + Minimum * minimumWidth<ElementCodec>();
    static_assert(Maximum <= std::numeric_limits<typename CountCodec::value_type>::max());
    static_assert(minimumWidth<ElementCodec>() > 0);

    static void validateCount(std::size_t count) {
      if (count < Minimum || count > Maximum) {
        throw EncodingError{"Invalid list count"};
      }
    }

    static std::size_t encodedSize(value_type values) {
      validateCount(values.size());
      std::size_t size = CountCodec::width;
      for (const auto &value : values) {
        size = checkedWireSize(size, wireSize<ElementCodec>(value));
      }

      return size;
    }

    static void encode(value_type values, std::span<Byte> &output) {
      if (output.size() < encodedSize(values)) {
        throw EncodingError{"Output buffer too small"};
      }

      CountCodec::encode(static_cast<typename CountCodec::value_type>(values.size()), output);
      for (const auto &value : values) {
        ElementCodec::encode(value, output);
      }
    }

    static value_type decode(std::span<const Byte> &input, DecodeStorage &storage) {
      const auto count = CountCodec::decode(input);
      validateCount(count);
      if (count > input.size() / minimumWidth<ElementCodec>()) {
        throw EncodingError{"Truncated list"};
      }

      auto values = storage.allocate<Element>(count);
      for (auto &value : values) {
        value = decodeValue<ElementCodec>(input, storage);
      }

      return values;
    }
  };

  template <typename Value> void validateBody(const Value &value) {
    if constexpr (requires { BodySchema<Value>::validate(value); }) {
      BodySchema<Value>::validate(value);
    }
  }

  template <typename Value> struct ValueCodec : CodecWidth<BodySchema<Value>> {
    using value_type = Value;
    static constexpr std::size_t min_width = minimumWidth<BodySchema<Value>>();

    static std::size_t encodedSize(const Value &value) {
      validateBody(value);

      return BodySchema<Value>::encodedSize(value);
    }

    static void encode(const Value &value, std::span<Byte> &output) {
      if (output.size() < encodedSize(value)) {
        throw EncodingError{"Output buffer too small"};
      }

      BodySchema<Value>::encodeBody(value, output);
    }

    static Value decode(std::span<const Byte> &input, DecodeStorage &storage) {
      Value value{};
      BodySchema<Value>::decodeBody(input, value, storage);
      validateBody(value);

      return value;
    }
  };

  // Unlike Codec, this entry point never adds a message tag or transport prefix.
  struct BodyCodec {
    template <typename Value, typename... Context>
    static std::size_t encodedSize(const Value &value, Context... context) {
      validateBody(value);

      return BodySchema<Value>::encodedSize(value, context...);
    }

    template <typename Value, typename... Context>
    static std::span<Byte> encode(const Value &value, std::span<Byte> buffer, Context... context) {
      const auto size = encodedSize(value, context...);
      if (buffer.size() < size) {
        throw EncodingError{"Output buffer too small"};
      }

      auto output = buffer.first(size);
      BodySchema<Value>::encodeBody(value, output, context...);
      if (!output.empty()) {
        throw EncodingError{"Body serializer size mismatch"};
      }

      return buffer.first(size);
    }

    template <typename Value, typename... Context>
    static Value decode(std::span<const Byte> input, DecodeStorage &storage, Context... context) {
      if (input.size() > max_payload_size) {
        throw EncodingError{"Encoded body exceeds the frame limit"};
      }

      Value value{};
      BodySchema<Value>::decodeBody(input, value, storage, context...);
      if (!input.empty()) {
        throw EncodingError{"Trailing bytes in body"};
      }
      validateBody(value);

      return value;
    }
  };

} // namespace telar
