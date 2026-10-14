#pragma once

#include <array>
#include <cstddef>
#include <span>
#include <variant>

#include "telar_serializer.hpp"

namespace telar {

  using SchemaId = std::array<Byte, 8>;

  namespace handshake {

    inline constexpr std::array<Byte, 8> magic{
        'T', 'E', 'L', 'A', 'R', 'I', 'P', 'C',
    };

    // Matches the single current schema in src/core/schema/handshake.zig.
    inline constexpr SchemaId schema_id{
        '8', '7', '6', 'b', '4', '8', '0', 'd',
    };

  } // namespace handshake

  enum class HandshakeTag : Byte {
    client_hello = 1,
    server_accept = 2,
    server_reject = 3,
  };

  enum class HandshakeRejectReason : Byte {
    incompatible_schema = 1,
    client_limit_reached = 2,
  };

  struct ClientHello {
    SchemaId schema = handshake::schema_id;
  };

  struct ServerAccept {
    SchemaId schema;
  };

  struct ServerReject {
    HandshakeRejectReason reason;
    SchemaId expected_schema;
  };

  using HandshakeResponse = std::variant<ServerAccept, ServerReject>;

  struct HandshakeReasonByte {
    static constexpr std::size_t width = u8::width;

    static HandshakeRejectReason validate(HandshakeRejectReason reason) _throw(EncodingError) {
      switch (reason) {
      case HandshakeRejectReason::incompatible_schema:
      case HandshakeRejectReason::client_limit_reached:
        return reason;
      default:
        throw EncodingError{"Unknown handshake rejection reason"};
      }
    }

    static void encode(HandshakeRejectReason reason, std::span<Byte> &output) _throw(EncodingError) {
      u8::encode(static_cast<Byte>(validate(reason)), output);
    }

    static HandshakeRejectReason decode(std::span<const Byte> &input) _throw(EncodingError) {
      return validate(static_cast<HandshakeRejectReason>(u8::decode(input)));
    }
  };

  template <Direction Side, HandshakeTag Tag, typename... Fields> struct HandshakeLayout : Schema<Side, Tag, Fields...> {
    static constexpr auto magic = handshake::magic;
    static constexpr std::size_t payload_size = magic.size() + Schema<Side, Tag, Fields...>::payload_size;

#ifdef TELAR_DEBUG
    template <typename Message> static void pretty_print(const Message &message, std::FILE *output = stderr);
#endif
  };

  using SchemaIdCodec = FixedBytes<SchemaId{}.size()>;

  template <typename Message> struct HandshakeSchema;

  template <> struct HandshakeSchema<ClientHello>
      : HandshakeLayout<Direction::client, HandshakeTag::client_hello,
                        Field<&ClientHello::schema, SchemaIdCodec, "schema">> {};

  template <> struct HandshakeSchema<ServerAccept>
      : HandshakeLayout<Direction::server, HandshakeTag::server_accept,
                        Field<&ServerAccept::schema, SchemaIdCodec, "schema">> {};

  template <> struct HandshakeSchema<ServerReject>
      : HandshakeLayout<Direction::server, HandshakeTag::server_reject,
                        Field<&ServerReject::reason, HandshakeReasonByte, "reason">,
                        Field<&ServerReject::expected_schema, SchemaIdCodec, "expected_schema">> {};

} // namespace telar
