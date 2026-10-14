#pragma once

#include "../codecs/telar_wire.hpp"

namespace telar {

  template <auto Member, typename WireCodec, FixedString Name = "<unnamed>">
  struct Field : CodecWidth<WireCodec> {
    static constexpr std::size_t min_width = minimumWidth<WireCodec>();

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      return wireSize<WireCodec>(message.*Member);
    }

    template <typename Message>
    static void encode(const Message &message, std::span<Byte> &output) _throw(EncodingError) {
      WireCodec::encode(message.*Member, output);
    }

    template <typename Message>
    static void decode(std::span<const Byte> &input, Message &message) _throw(EncodingError) {
      message.*Member = WireCodec::decode(input);
    }

    template <typename Message, typename Storage>
    static void decode(std::span<const Byte> &input, Message &message, Storage &storage) {
      message.*Member = decodeValue<WireCodec>(input, storage);
    }

#ifdef TELAR_DEBUG
    static void prettyPrint(std::span<const Byte> &input, std::FILE *output) {
      constexpr auto width = WireCodec::width;
      const auto bytes = input.first(width);
      const auto value = debug::valueText(WireCodec::decode(input));

      debug::printBytes(bytes, Name.value, value.data(), output, !input.empty());
    }

    static void prettyPrintLabel(std::span<const Byte> &input, std::FILE *output) {
      constexpr auto width = WireCodec::width;
      const auto value = debug::valueText(WireCodec::decode(input));

      debug::printLabel(width, Name.value, value.data(), output, !input.empty());
    }

    static void prettyPrintValue(std::span<const Byte> &input, std::FILE *output) {
      constexpr auto width = WireCodec::width;
      const auto value = debug::valueText(WireCodec::decode(input));

      debug::printValue(width, Name.value, value.data(), output, !input.empty());
    }
#endif
  };

  template <typename Message> struct MessageSchema;
  template <typename Value> struct BodySchema;

  template <typename... Fields> struct SerializerSize {};

  template <typename... Fields>
    requires((requires { Fields::width; }) && ...)
  struct SerializerSize<Fields...> {
    static constexpr std::size_t payload_size = (std::size_t{0} + ... + Fields::width);
    static constexpr std::size_t width = payload_size;
  };

  template <typename... Fields> struct Serializer : SerializerSize<Fields...> {
    static constexpr std::size_t min_width = (std::size_t{0} + ... + Fields::min_width);
    static constexpr bool fixed_size = requires { SerializerSize<Fields...>::payload_size; };

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      std::size_t size = 0;
      ((size = checkedWireSize(size, Fields::encodedSize(message))), ...);

      return size;
    }

    template <typename Message>
    static void encodeBody(const Message &message, _changes std::span<Byte> &output)
        _throw(EncodingError) {
      (Fields::encode(message, output), ...);
    }

    template <typename Message>
    static void decodeBody(std::span<const Byte> &input, _changes Message &message)
        _throw(EncodingError) {
      (Fields::decode(input, message), ...);
    }

    template <typename Message, typename Storage>
    static void decodeBody(std::span<const Byte> &input, Message &message, Storage &storage) {
      (Fields::decode(input, message, storage), ...);
    }

#ifdef TELAR_DEBUG
    static void pretty_print_fields(std::span<const Byte> input, std::FILE *output) {
      (Fields::prettyPrint(input, output), ...);
    }

    static void pretty_print_labels(std::span<const Byte> input, std::FILE *output) {
      (Fields::prettyPrintLabel(input, output), ...);
    }

    static void pretty_print_values(std::span<const Byte> input, std::FILE *output) {
      (Fields::prettyPrintValue(input, output), ...);
    }
#endif
  };

  template <Direction Side, auto Tag, typename... Fields> struct Schema : Serializer<Fields...> {
    static constexpr Direction direction = Side;
    static constexpr auto tag = Tag;
    static constexpr std::size_t payload_size = u8::width + Serializer<Fields...>::payload_size;

#ifdef TELAR_DEBUG
    template <typename Message>
    static void pretty_print(const Message &message, std::FILE *output = stderr);
#endif
  };

} // namespace telar
