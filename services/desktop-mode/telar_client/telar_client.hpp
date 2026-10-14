#pragma once

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <span>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include "codecs/telar_codec.hpp"
#include "codecs/telar_handshake.hpp"

namespace telar {

  struct SocketError final : std::exception {
    SocketError(const char *message) : message{message} {}

    const char *what() const noexcept override { return message; }

  private:
    const char *message;
  };

  class Client final {
  public:
    static Client init(const char *socket_path) _throw(SocketError) {
      Client client{};
      client._address.sun_family = AF_UNIX;

      if (std::strlen(socket_path) >= sizeof(client._address.sun_path)) {
        throw SocketError{"Socket path too long"};
      }

      std::strcpy(client._address.sun_path, socket_path);

      client._fd = socket(AF_UNIX, SOCK_STREAM, 0);
      if (client._fd < 0) {
        throw SocketError{"Error opening socket"};
      }

      if (setsockopt(client._fd, SOL_SOCKET, SO_RCVTIMEO, &io_timeout, sizeof(io_timeout)) < 0 ||
          setsockopt(client._fd, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout)) < 0) {
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

      auto address_ptr = reinterpret_cast<sockaddr *>(&client._address);
      while (connect(client._fd, address_ptr, sizeof(client._address)) < 0) {
        if (errno == EINTR) {
          continue;
        }

        client.deinit();
        throw SocketError{"Error connecting"};
      }

      return client;
    }

    void handshake() _throw(std::exception) {
      try {
        const ClientHello request{};
        sendFrame(HandshakeCodec::encode(request));

        std::array<Byte, HandshakeCodec::max_message_size> buffer{};
        const auto response = HandshakeCodec::decodeResponse(receiveFrame(buffer));

        if (const auto *accepted = std::get_if<ServerAccept>(&response)) {
          if (accepted->schema != request.schema) {
            throw SocketError{"Runtime accepted an unexpected wire schema"};
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

    void deinit() {
      if (_fd >= 0) {
        close(_fd);
        _fd = -1;
      }
    }

    template <typename Message> void send(const Message &message) {
      using Schema = MessageSchema<Message>;
      static_assert(Schema::direction == Direction::client, "Can only send Client Messages");

      sendFrame(Codec::encode(message));
    }

    template <typename Message> void send(const Message &message, std::span<Byte> frame_buffer) {
      static_assert(MessageSchema<Message>::direction == Direction::client, "Can only send Client Messages");
      if (frame_buffer.size() < frame_prefix_size) {
        throw EncodingError{"Frame buffer too small"};
      }

      const auto payload = Codec::encode(message, frame_buffer.subspan(frame_prefix_size));
      auto prefix = frame_buffer.first(frame_prefix_size);
      u32::encode(static_cast<std::uint32_t>(payload.size()), prefix);
      writeAll(frame_buffer.data(), frame_prefix_size + payload.size());
    }

    std::span<const Byte> receiveFrame(std::span<Byte> buffer) _throw(SocketError) {
      try {
        std::array<Byte, frame_prefix_size> prefix{};
        readAll(prefix.data(), prefix.size());

        std::span<const Byte> input = prefix;
        const auto length = u32::decode(input);
        if (length == 0 || length > max_payload_size || length > buffer.size()) {
          throw SocketError{"Invalid runtime frame length"};
        }

        readAll(buffer.data(), length);
        return buffer.first(length);
      } catch (...) {
        deinit();
        throw;
      }
    }

  private:
    static constexpr timeval io_timeout{
        .tv_sec = 30,
        .tv_usec = 0,
    };

    template <std::size_t N>
    void sendFrame(const std::array<Byte, N> &payload) _throw(SocketError) {
      static_assert(N > 0 && N <= max_payload_size, "Invalid runtime frame length");
      std::array<Byte, frame_prefix_size + N> frame{};
      std::span<Byte> output = frame;
      u32::encode(static_cast<std::uint32_t>(payload.size()), output);

      std::memcpy(output.data(), payload.data(), payload.size());
      writeAll(frame.data(), frame.size());
    }

    void writeAll(const std::uint8_t *bytes, std::size_t size) _throw(SocketError) {
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

    void readAll(std::uint8_t *bytes, std::size_t size) _throw(SocketError) {
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
