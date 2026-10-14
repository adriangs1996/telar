#pragma once

#include "../codecs/telar_wire.hpp"

#include <limits>

namespace telar {

  template <auto Member, typename Message> decltype(auto) memberValue(Message &message) {
    if constexpr (std::is_member_object_pointer_v<decltype(Member)>) {
      return (message.*Member);
    } else {
      return Member(message);
    }
  }

  template <auto Member, typename WireCodec, FixedString Name = "<unnamed>">
  struct Field : CodecWidth<WireCodec> {
    static constexpr std::size_t min_width = minimumWidth<WireCodec>();

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      return wireSize<WireCodec>(memberValue<Member>(message));
    }

    template <typename Message>
    static void encode(const Message &message, std::span<Byte> &output) _throw(EncodingError) {
      WireCodec::encode(memberValue<Member>(message), output);
    }

    template <typename Message>
    static void decode(std::span<const Byte> &input, Message &message) _throw(EncodingError) {
      memberValue<Member>(message) = WireCodec::decode(input);
    }

    template <typename Message, typename Storage>
    static void decode(std::span<const Byte> &input, Message &message, Storage &storage) {
      memberValue<Member>(message) = decodeValue<WireCodec>(input, storage);
    }

    template <typename Message, typename Visitor>
    static void visit(const Message &message, std::span<const Byte> &input, Visitor visitor) {
      const auto size = encodedSize(message);
      visitor(Name.value, input.first(size), memberValue<Member>(message));
      input = input.subspan(size);
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

  template <auto Member, auto ContextMember, typename WireCodec, FixedString Name>
  struct ContextField {
    static constexpr std::size_t min_width = WireCodec::min_width;

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      return WireCodec::encodedSize(memberValue<Member>(message), memberValue<ContextMember>(message));
    }

    template <typename Message> static void encode(const Message &message, std::span<Byte> &output) {
      WireCodec::encode(memberValue<Member>(message), output, memberValue<ContextMember>(message));
    }

    template <typename Message> static void decode(std::span<const Byte> &input, Message &message, DecodeStorage &storage) {
      memberValue<Member>(message) = WireCodec::decode(input, storage, memberValue<ContextMember>(message));
    }

    template <typename Message, typename Visitor>
    static void visit(const Message &message, std::span<const Byte> &input, Visitor visitor) {
      const auto size = encodedSize(message);
      visitor(Name.value, input.first(size), memberValue<Member>(message));
      input = input.subspan(size);
    }
  };

  // Some messages put the count before other headers and the items afterwards.
  // This pair keeps that order without storing a redundant count in the DTO.
  template <auto Member, typename CountCodec, typename ElementCodec, std::size_t Maximum,
            FixedString Name, std::size_t Minimum = 0>
  struct SpanCountField {
    static constexpr std::size_t width = CountCodec::width;
    static constexpr std::size_t min_width = width;

    static void validate(std::size_t count) {
      if (count < Minimum || count > Maximum || count > std::numeric_limits<typename CountCodec::value_type>::max()) {
        throw EncodingError{"Invalid separated list count"};
      }
    }

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      validate(memberValue<Member>(message).size());
      return width;
    }

    template <typename Message> static void encode(const Message &message, std::span<Byte> &output) {
      (void)encodedSize(message);
      CountCodec::encode(static_cast<typename CountCodec::value_type>(memberValue<Member>(message).size()), output);
    }

    template <typename Message> static void decode(std::span<const Byte> &input, Message &message, DecodeStorage &storage) {
      const auto count = CountCodec::decode(input);
      validate(count);
      if (count > input.size() / minimumWidth<ElementCodec>()) {
        throw EncodingError{"Truncated separated list"};
      }
      memberValue<Member>(message) = storage.allocate<typename ElementCodec::value_type>(count);
    }

    template <typename Message, typename Visitor>
    static void visit(const Message &message, std::span<const Byte> &input, Visitor visitor) {
      visitor(Name.value, input.first(width), memberValue<Member>(message).size());
      input = input.subspan(width);
    }
  };

  template <auto Member, typename ElementCodec, FixedString Name> struct SpanItemsField {
    static constexpr std::size_t min_width = 0;

    template <typename Message> static std::size_t encodedSize(const Message &message) {
      std::size_t size = 0;
      for (const auto &value : memberValue<Member>(message)) {
        size = checkedWireSize(size, wireSize<ElementCodec>(value));
      }
      return size;
    }

    template <typename Message> static void encode(const Message &message, std::span<Byte> &output) {
      for (const auto &value : memberValue<Member>(message)) {
        ElementCodec::encode(value, output);
      }
    }

    template <typename Message> static void decode(std::span<const Byte> &input, Message &message, DecodeStorage &storage) {
      auto values = memberValue<Member>(message);
      if (values.size() > input.size() / minimumWidth<ElementCodec>()) {
        throw EncodingError{"Truncated separated list items"};
      }
      // SpanCountField created these mutable objects in the caller's storage.
      auto *output = const_cast<typename ElementCodec::value_type *>(values.data());
      for (std::size_t i = 0; i < values.size(); ++i) {
        output[i] = decodeValue<ElementCodec>(input, storage);
      }
    }

    template <typename Message, typename Visitor>
    static void visit(const Message &message, std::span<const Byte> &input, Visitor visitor) {
      const auto size = encodedSize(message);
      visitor(Name.value, input.first(size), memberValue<Member>(message));
      input = input.subspan(size);
    }
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

    template <typename Message, typename Visitor>
    static void visitFields(const Message &message, std::span<const Byte> &input, Visitor visitor) {
      (Fields::visit(message, input, visitor), ...);
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

  template <typename Body, bool Fixed = Body::fixed_size> struct MessageSize : Body {};

  template <typename Body> struct MessageSize<Body, true> : Body {
    static constexpr std::size_t payload_size = u8::width + Body::payload_size;
  };

  template <Direction Side, auto Tag, typename Body>
  struct MessageLayout : MessageSize<Body> {
    static constexpr Direction direction = Side;
    static constexpr auto tag = Tag;

#ifdef TELAR_DEBUG
    template <typename Message>
    static void pretty_print(const Message &message, std::FILE *output = stderr);
#endif
  };

  template <Direction Side, auto Tag, typename... Fields>
  struct Schema : MessageLayout<Side, Tag, Serializer<Fields...>> {};

} // namespace telar
