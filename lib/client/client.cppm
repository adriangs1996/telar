module;
#include "tbc/annotations.hpp"
#include "telar_client/codecs/telar_annotations.hpp"

export module telar.client;

import std;
import telar.tbc;

import telar.base.text.utf8;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.sys.posix;
import telar.sys.socket;

// The connection reports request failures with it; the rest of the wire
// vocabulary stays with telar.wire.vocabulary.
export namespace telar::runtime {
  using telar::runtime::RequestError;
}

// Interface: telar_client/serializers/telar_handshake.cppm
export {
  namespace telar {

    using SchemaId = std::array<Byte, 8>;

    namespace handshake {

      inline constexpr std::array<Byte, 8> magic{
          'T',
          'E',
          'L',
          'A',
          'R',
          'I',
          'P',
          'C',
      };

      // cqp00002 added PaneShell, PaneGit, PaneBlocks, word completion and command specs;
      // cqp00003 added ReadPaneRows, PaneRows, PaneScrollback, SearchPaneRows, PaneCommand and
      // ConfigureShellPrompt; cqp00004 adds PaneDocument. Peers without them reject the messages.
      inline constexpr SchemaId schema_id{'c', 'q', 'p', '0', '0', '0', '0', '4'};

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

      static HandshakeRejectReason validate(HandshakeRejectReason reason) _throw(EncodingError);

      static void encode(HandshakeRejectReason reason, std::span<Byte>& output) _throw(EncodingError);

      static HandshakeRejectReason decode(std::span<const Byte>& input) _throw(EncodingError);
    };

    template <Direction Side, HandshakeTag Tag, typename... Fields>
    struct HandshakeLayout : Schema<Side, Tag, Fields...> {
      static constexpr auto magic = handshake::magic;
      static constexpr std::size_t payload_size =
          magic.size() + Schema<Side, Tag, Fields...>::payload_size;

#ifdef TELAR_DEBUG
      template <typename Message>
      static void pretty_print(const Message& message, std::FILE* output = stderr);
#endif
    };

    using SchemaIdCodec = FixedBytes<SchemaId{}.size()>;

    template <typename Message>
    struct HandshakeSchema;

    template <>
    struct HandshakeSchema<ClientHello>
        : HandshakeLayout<Direction::client, HandshakeTag::client_hello, Field<&ClientHello::schema, SchemaIdCodec, "schema">> {};

    template <>
    struct HandshakeSchema<ServerAccept>
        : HandshakeLayout<Direction::server, HandshakeTag::server_accept, Field<&ServerAccept::schema, SchemaIdCodec, "schema">> {};

    template <>
    struct HandshakeSchema<ServerReject>
        : HandshakeLayout<Direction::server, HandshakeTag::server_reject, Field<&ServerReject::reason, HandshakeReasonByte, "reason">, Field<&ServerReject::expected_schema, SchemaIdCodec, "expected_schema">> {};

  } // namespace telar
}

export {
  namespace telar {

    struct HandshakeCodec {
      static constexpr std::size_t max_message_size = HandshakeSchema<ServerReject>::payload_size;

      template <typename Message>
      static std::array<Byte, HandshakeSchema<Message>::payload_size> encode(const Message& message) _throw(EncodingError);

      template <typename Message>
      static Message decode(std::span<const Byte> input) _throw(EncodingError);

      static HandshakeResponse decodeResponse(std::span<const Byte> input) _throw(EncodingError);

#ifdef TELAR_DEBUG
      template <typename Message>
      static void pretty_print(const Message& message, std::FILE* output = stderr);
#endif

    private:
      static constexpr std::size_t header_size = handshake::magic.size() + u8::width;

      static HandshakeTag decodeHeader(std::span<const Byte>& input) _throw(EncodingError);

      template <typename Message>
      static Message decodeBody(std::span<const Byte> input) _throw(EncodingError);
    };

    static_assert(HandshakeSchema<ClientHello>::payload_size == 17);
    static_assert(HandshakeSchema<ServerAccept>::payload_size == 17);
    static_assert(HandshakeSchema<ServerReject>::payload_size == 18);

  } // namespace telar
}

// Interface: telar_client/codecs.cppm
export {
}

// Interface: telar_client/serializers.cppm
export {
}

// Interface: telar_client/telar_client.cppm
export {
  namespace telar {

    struct SocketError final : std::exception {
      SocketError(const char* message);

      const char* what() const noexcept override;

    private:
      const char* message;
    };

    // Owns its socket: closed when the client goes, moved but never copied, and never inherited
    // by a program the process runs.
    class Client final {
    public:
      Client() = default;
      Client(const Client&) = delete;
      Client& operator=(const Client&) = delete;

      Client(Client&& other) noexcept;
      Client& operator=(Client&& other) noexcept;
      ~Client();

      static Client init(const char* socket_path) _throw(SocketError);

      void handshake() _throw(std::exception);

      void deinit();

      template <typename Message>
      TBC_GENERIC inline void send(const Message& message) {
        using Schema = MessageSchema<Message>;
        static_assert(Schema::direction == Direction::client, "Can only send Client Messages");

        sendFrame(Codec::encode(message));
      }

      template <typename Message>
      TBC_GENERIC inline void send(const Message& message, std::span<Byte> frame_buffer) {
        static_assert(MessageSchema<Message>::direction == Direction::client, "Can only send Client Messages");

        if (frame_buffer.size() < frame_prefix_size) {
          throw EncodingError{"Frame buffer too small"};
        }

        const auto payload = Codec::encode(message, frame_buffer.subspan(frame_prefix_size));
        auto prefix = frame_buffer.first(frame_prefix_size);

        u32::encode(static_cast<std::uint32_t>(payload.size()), prefix);
        writeAll(frame_buffer.data(), frame_prefix_size + payload.size());
      }

      tbc::view<std::span<const Byte>, tbc::lt::a> receiveFrame(tbc::view<std::span<Byte>, tbc::lt::a> buffer) _throw(SocketError);

      int descriptor() const noexcept;

      void interrupt() const noexcept;

    private:
      static constexpr timeval io_timeout{
          .tv_sec = 30,
          .tv_usec = 0,
      };

      template <std::size_t N>
      TBC_GENERIC inline void sendFrame(const std::array<Byte, N>& payload) _throw(SocketError) {
        static_assert(N > 0 && N <= max_payload_size, "Invalid runtime frame length");
        std::array<Byte, frame_prefix_size + N> frame{};
        std::span<Byte> output = frame;

        u32::encode(static_cast<std::uint32_t>(payload.size()), output);

        std::memcpy(output.data(), payload.data(), payload.size());
        writeAll(frame.data(), frame.size());
      }

      void writeAll(const std::uint8_t* bytes, std::size_t size) _throw(SocketError);

      void readAll(std::uint8_t* bytes, std::size_t size) _throw(SocketError);

      sockaddr_un _address = {};
      int _fd = -1;
    };

  } // namespace telar
}

// Interface: telar_client/telar.cppm
export {
}
