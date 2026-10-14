#pragma once

#include "telar_codec.hpp"
#include "../serializers/telar_handshake.hpp"

namespace telar {

  struct HandshakeCodec {
    static constexpr std::size_t max_message_size = HandshakeSchema<ServerReject>::payload_size;

    template <typename Message> static auto encode(const Message &message) _throw(EncodingError) {
      using Sch = HandshakeSchema<Message>;
      std::array<Byte, Sch::payload_size> payload{};
      std::span<Byte> output = payload;

      FixedBytes<handshake::magic.size()>::encode(handshake::magic, output);
      u8::encode(static_cast<Byte>(Sch::tag), output);
      Sch::encodeBody(message, output);

      return payload;
    }

    template <typename Message> static Message decode(std::span<const Byte> input) _throw(EncodingError) {
      if (decodeHeader(input) != HandshakeSchema<Message>::tag) {
        throw EncodingError{"Unexpected handshake message"};
      }

      return decodeBody<Message>(input);
    }

    static HandshakeResponse decodeResponse(std::span<const Byte> input) _throw(EncodingError) {
      switch (decodeHeader(input)) {
      case HandshakeTag::server_accept:
        return decodeBody<ServerAccept>(input);
      case HandshakeTag::server_reject:
        return decodeBody<ServerReject>(input);
      default:
        throw EncodingError{"Unexpected handshake response"};
      }
    }

#ifdef TELAR_DEBUG
    template <typename Message> static void pretty_print(const Message &message, std::FILE *output = stderr) {
      const auto payload = encode(message);
      debug::printFrame<HandshakeSchema<Message>>(payload, output);
    }
#endif

  private:
    static constexpr std::size_t header_size = handshake::magic.size() + u8::width;

    static HandshakeTag decodeHeader(std::span<const Byte> &input) _throw(EncodingError) {
      if (input.size() < header_size) {
        throw EncodingError{"Invalid handshake response length"};
      }

      if (FixedBytes<handshake::magic.size()>::decode(input) != handshake::magic) {
        throw EncodingError{"Invalid handshake magic"};
      }

      const auto tag = static_cast<HandshakeTag>(u8::decode(input));
      switch (tag) {
      case HandshakeTag::client_hello:
      case HandshakeTag::server_accept:
      case HandshakeTag::server_reject:
        return tag;
      default:
        throw EncodingError{"Unknown handshake message tag"};
      }
    }

    template <typename Message> static Message decodeBody(std::span<const Byte> input) _throw(EncodingError) {
      using Sch = HandshakeSchema<Message>;
      if (input.size() != Sch::payload_size - header_size) {
        throw EncodingError{"Invalid handshake response length"};
      }

      Message message{};
      Sch::decodeBody(input, message);
      return message;
    }
  };

#ifdef TELAR_DEBUG
  template <Direction Side, HandshakeTag Tag, typename... Fields>
  template <typename Message>
  void HandshakeLayout<Side, Tag, Fields...>::pretty_print(const Message &message, std::FILE *output) {
    HandshakeCodec::pretty_print(message, output);
  }
#endif

  static_assert(HandshakeSchema<ClientHello>::payload_size == 17);
  static_assert(HandshakeSchema<ServerAccept>::payload_size == 17);
  static_assert(HandshakeSchema<ServerReject>::payload_size == 18);

} // namespace telar
