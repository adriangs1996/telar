module;
#include "tbc/view.hpp"
#include "telar_client/codecs/telar_annotations.hpp"
#include <cstdio>
#include <cstdlib>

#include <cstddef>

#include <cstdint>

#include <cstring>

#include <new>

#include <cerrno>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

export module telar.client;

import std;

export import telar.base.text;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;

// The connection reports request failures with it; the rest of the protocol
// stays with telar.client.protocol.
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

      inline static HandshakeRejectReason validate(HandshakeRejectReason reason) _throw(EncodingError) {
        switch (reason) {
        case HandshakeRejectReason::incompatible_schema:
        case HandshakeRejectReason::client_limit_reached:
          return reason;
        default:
          throw EncodingError{"Unknown handshake rejection reason"};
        }
      }

      inline static void encode(HandshakeRejectReason reason, std::span<Byte>& output) _throw(EncodingError) {
        u8::encode(static_cast<Byte>(validate(reason)), output);
      }

      inline static HandshakeRejectReason decode(std::span<const Byte>& input) _throw(EncodingError) {
        return validate(static_cast<HandshakeRejectReason>(u8::decode(input)));
      }
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
      inline static auto encode(const Message& message) _throw(EncodingError) {
        using Sch = HandshakeSchema<Message>;
        std::array<Byte, Sch::payload_size> payload{};
        std::span<Byte> output = payload;

        FixedBytes<handshake::magic.size()>::encode(handshake::magic, output);
        u8::encode(static_cast<Byte>(Sch::tag), output);
        Sch::encodeBody(message, output);

        return payload;
      }

      template <typename Message>
      inline static Message decode(std::span<const Byte> input) _throw(EncodingError) {
        if (decodeHeader(input) != HandshakeSchema<Message>::tag) {
          throw EncodingError{"Unexpected handshake message"};
        }

        return decodeBody<Message>(input);
      }

      inline static HandshakeResponse decodeResponse(std::span<const Byte> input) _throw(EncodingError) {
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
      template <typename Message>
      inline static void pretty_print(const Message& message, std::FILE* output = stderr) {
        const auto payload = encode(message);

        debug::printFrame<HandshakeSchema<Message>>(payload, output);
      }
#endif

    private:
      static constexpr std::size_t header_size = handshake::magic.size() + u8::width;

      inline static HandshakeTag decodeHeader(std::span<const Byte>& input) _throw(EncodingError) {
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

      template <typename Message>
      inline static Message decodeBody(std::span<const Byte> input) _throw(EncodingError) {
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
    void HandshakeLayout<Side, Tag, Fields...>::pretty_print(const Message& message, std::FILE* output) {
      HandshakeCodec::pretty_print(message, output);
    }
#endif

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
      inline SocketError(const char* message)
          : message{message} {}

      inline const char* what() const noexcept override {
        return message;
      }

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

      inline Client(Client&& other) noexcept
          : _address(other._address),
            _fd(std::exchange(other._fd, -1)) {}

      inline Client& operator=(Client&& other) noexcept {
        if (this != &other) {
          deinit();
          _address = other._address;
          _fd = std::exchange(other._fd, -1);
        }

        return *this;
      }

      inline ~Client() {
        deinit();
      }

      inline static Client init(const char* socket_path) _throw(SocketError) {
        Client client{};

        client._address.sun_family = AF_UNIX;

        const auto path_length = std::strlen(socket_path);
        if (path_length >= sizeof(client._address.sun_path)) {
          throw SocketError{"Socket path too long"};
        }

        std::memcpy(client._address.sun_path, socket_path, path_length + 1);

#ifdef SOCK_CLOEXEC
        client._fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
        // Without SOCK_CLOEXEC a fork between these two calls can still inherit it.
        client._fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (client._fd >= 0 && fcntl(client._fd, F_SETFD, FD_CLOEXEC) < 0) {
          client.deinit();
          throw SocketError{"Error configuring socket"};
        }

#endif
        if (client._fd < 0) {
          throw SocketError{"Error opening socket"};
        }

        if (setsockopt(client._fd, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout)) < 0) {
          client.deinit();
          throw SocketError{"Error configuring runtime I/O timeout"};
        }

#ifdef SO_NOSIGPIPE
        const int enabled = 1;
        if (setsockopt(client._fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
          client.deinit();
          throw SocketError{"Error configuring socket"};
        }
#endif

        auto address_ptr = reinterpret_cast<sockaddr*>(&client._address);

        while (connect(client._fd, address_ptr, sizeof(client._address)) < 0) {
          if (errno == EINTR) {
            continue;
          }

          client.deinit();
          throw SocketError{"Error connecting"};
        }

        return client;
      }

      inline void handshake() _throw(std::exception) {
        timeval timeout{
            .tv_sec = 30,
            .tv_usec = 0,
        };

        if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
          throw SocketError{"Error enabling runtime receive timeout for handshake"};
        }

        try {
          const ClientHello request{};

          sendFrame(HandshakeCodec::encode(request));

          std::array<Byte, HandshakeCodec::max_message_size> buffer{};
          const auto response = HandshakeCodec::decodeResponse(receiveFrame(buffer));

          if (const auto* accepted = std::get_if<ServerAccept>(&response)) {
            if (accepted->schema != request.schema) {
              throw SocketError{"Runtime accepted an unexpected wire schema"};
            }

            timeout.tv_sec = 0;
            if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
              throw SocketError{"Error disabling runtime receive timeout"};
            }

            return;
          }

          switch (std::get<ServerReject>(response).reason) {
          case HandshakeRejectReason::incompatible_schema:
            throw SocketError{"Runtime rejected the wire schema"};
          case HandshakeRejectReason::client_limit_reached:
            throw SocketError{"Runtime client limit reached"};
          }
        } catch (...) {
          deinit();
          throw;
        }
      }

      inline void deinit() {
        if (_fd >= 0) {
          close(_fd);
          _fd = -1;
        }
      }

      template <typename Message>
      inline void send(const Message& message) {
        using Schema = MessageSchema<Message>;
        static_assert(Schema::direction == Direction::client, "Can only send Client Messages");

        sendFrame(Codec::encode(message));
      }

      template <typename Message>
      inline void send(const Message& message, std::span<Byte> frame_buffer) {
        static_assert(MessageSchema<Message>::direction == Direction::client, "Can only send Client Messages");

        if (frame_buffer.size() < frame_prefix_size) {
          throw EncodingError{"Frame buffer too small"};
        }

        const auto payload = Codec::encode(message, frame_buffer.subspan(frame_prefix_size));
        auto prefix = frame_buffer.first(frame_prefix_size);

        u32::encode(static_cast<std::uint32_t>(payload.size()), prefix);
        writeAll(frame_buffer.data(), frame_prefix_size + payload.size());
      }

      inline tbc::view<std::span<const Byte>, tbc::lt::a> receiveFrame(tbc::view<std::span<Byte>, tbc::lt::a> buffer) _throw(SocketError) {
        std::array<Byte, frame_prefix_size> prefix{};

        readAll(prefix.data(), prefix.size());

        std::span<const Byte> input = prefix;
        const auto length = u32::decode(input);
        if (length == 0 || length > max_payload_size || length > buffer.size()) {
          throw SocketError{"Invalid runtime frame length"};
        }

        readAll(buffer.data(), length);
        return buffer.first(length);
      }

      inline int descriptor() const noexcept {
        return _fd;
      }

      inline void interrupt() const noexcept {
        if (_fd >= 0) {
          ::shutdown(_fd, SHUT_RDWR);
        }
      }

    private:
      static constexpr timeval io_timeout{
          .tv_sec = 30,
          .tv_usec = 0,
      };

      template <std::size_t N>
      inline void sendFrame(const std::array<Byte, N>& payload) _throw(SocketError) {
        static_assert(N > 0 && N <= max_payload_size, "Invalid runtime frame length");
        std::array<Byte, frame_prefix_size + N> frame{};
        std::span<Byte> output = frame;

        u32::encode(static_cast<std::uint32_t>(payload.size()), output);

        std::memcpy(output.data(), payload.data(), payload.size());
        writeAll(frame.data(), frame.size());
      }

      inline void writeAll(const std::uint8_t* bytes, std::size_t size) _throw(SocketError) {
        while (size != 0) {
#ifdef MSG_NOSIGNAL
          const auto count = ::send(_fd, bytes, size, MSG_NOSIGNAL);
#else
          const auto count = ::send(_fd, bytes, size, 0);
#endif
          if (count < 0 && errno == EINTR) {
            continue;
          }

          if (count <= 0) {
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
              throw SocketError{"Runtime send timed out"};
            }

            throw SocketError{"Error sending runtime message"};
          }

          bytes += count;
          size -= static_cast<std::size_t>(count);
        }
      }

      inline void readAll(std::uint8_t* bytes, std::size_t size) _throw(SocketError) {
        while (size != 0) {
          const auto count = recv(_fd, bytes, size, 0);
          if (count < 0 && errno == EINTR) {
            continue;
          }

          if (count < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
              throw SocketError{"Runtime receive timed out"};
            }

            throw SocketError{"Error receiving runtime message"};
          }

          if (count == 0) {
            throw SocketError{"Runtime closed the connection"};
          }

          bytes += count;
          size -= static_cast<std::size_t>(count);
        }
      }

      sockaddr_un _address = {};
      int _fd = -1;
    };

  } // namespace telar
}

// Interface: telar_client/telar.cppm
export {
}
