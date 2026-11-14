module;
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>

export module telar.platform.net;

import std;

import telar.platform.error;
import telar.platform.primitives;

// Interface: platform/byte_stream.cppm
export {
  namespace telar::runtime {

    enum class StreamReadiness {
      none,
      readable,
      writable,
      completion,
    };

    struct StreamResult {
      enum class State {
        data,
        blocked,
        ended,
        failed,
      };

      State state;
      std::size_t bytes = 0;
      StreamReadiness waiting = StreamReadiness::none;
    };

    struct StreamView {
      // The stream keeps these bytes stable until consume(), including write retries.
      StreamResult::State state;
      std::span<const std::uint8_t> bytes;
      StreamReadiness waiting = StreamReadiness::none;
    };

    template <typename Stream>
    concept ByteStream = requires(Stream& stream, std::span<std::uint8_t> destination, std::span<const std::uint8_t> bytes) {
      { stream.read(destination) } noexcept -> std::same_as<StreamResult>;
      { stream.write(bytes) } noexcept -> std::same_as<StreamResult>;
      { stream.halfClose() } noexcept -> std::same_as<void>;
    };

    template <typename Stream>
    concept PeekableByteStream = ByteStream<Stream> && requires(Stream& stream, std::span<std::uint8_t> destination) {
      { stream.peek(destination) } noexcept -> std::same_as<StreamResult>;
    };

    template <typename Stream>
    concept BufferedByteStream = ByteStream<Stream> && requires(Stream& stream, std::size_t bytes) {
      { stream.peekView(bytes) } noexcept -> std::same_as<StreamView>;
      { stream.consume(bytes) } noexcept -> std::same_as<void>;
    };

  }
}

// Interface: telar_platform/socket_would_block.cppm
export {
  namespace telar::runtime {

    // Whether a nonblocking socket call that failed with `error` may simply be tried again later.
    bool socketWouldBlock(int error) noexcept;

  }
}

// Interface: telar_platform/socket_signals.cppm
export {
  namespace telar::runtime {

    void suppressSocketSignals(int descriptor);

  }
}

// Interface: telar_platform/peer_credentials.cppm
export {
  namespace telar::runtime {

    struct PeerCredentials {
      uid_t user;
      gid_t group;
    };

    std::optional<PeerCredentials> peerCredentials(int socket) noexcept;

  }
}

// Interface: proxy/network_address.cppm
export {
  namespace telar::runtime {

    struct NetworkAddress {
      sockaddr_storage storage{};
      socklen_t length = 0;

      static NetworkAddress ipv4(const in_addr& host, std::uint16_t port = 0) noexcept;
      static NetworkAddress ipv6(const in6_addr& host, std::uint16_t port = 0) noexcept;
      static std::optional<NetworkAddress> copy(const sockaddr* source, socklen_t size) noexcept;

      void setPort(std::uint16_t port) noexcept;
      const sockaddr* address() const noexcept;
    };

  }
}

// Interface: proxy/socket.cppm
export {
  namespace telar::runtime {

    void configureProxySocket(int socket);
    FileDescriptor openOriginSocket(int family);

  }
}

// Interface: proxy/socket_stream.cppm
export {
  namespace telar::runtime {

    class SocketStream {
    public:
      explicit SocketStream(int descriptor) noexcept;

      StreamResult read(std::span<std::uint8_t> destination) noexcept;
      StreamResult peek(std::span<std::uint8_t> destination) noexcept;
      StreamResult write(std::span<const std::uint8_t> bytes) noexcept;
      void halfClose() noexcept;

    private:
      static StreamResult result(ssize_t count, StreamReadiness waiting) noexcept;

      int descriptor_;
    };

    static_assert(ByteStream<SocketStream>);
    static_assert(PeekableByteStream<SocketStream>);

  }
}
