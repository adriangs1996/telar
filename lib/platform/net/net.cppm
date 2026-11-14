module;
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

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
    inline bool socketWouldBlock(int error) noexcept {
      return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
    }

  }
}

// Interface: telar_platform/socket_signals.cppm
export {
  namespace telar::runtime {

    inline void suppressSocketSignals(int descriptor) {
#if defined(__APPLE__)
      const int enabled = 1;
      if (::setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Disable socket SIGPIPE"};
      }
#else
      (void)descriptor;
      if (::signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        throw SystemError{"Disable socket SIGPIPE"};
      }
#endif
    }

  }
}

// Interface: telar_platform/peer_credentials.cppm
export {
  namespace telar::runtime {

    struct PeerCredentials {
      uid_t user;
      gid_t group;
    };

    inline std::optional<PeerCredentials> peerCredentials(int socket) noexcept {
#if defined(__APPLE__)
      PeerCredentials credentials{};
      if (::getpeereid(socket, &credentials.user, &credentials.group) != 0) {
        return std::nullopt;
      }

      return credentials;
#else
      ucred credentials{};
      socklen_t length = sizeof(credentials);
      if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials)) {
        return std::nullopt;
      }
      return PeerCredentials{credentials.uid, credentials.gid};
#endif
    }

  }
}

// Interface: proxy/network_address.cppm
export {
  namespace telar::runtime {

    struct NetworkAddress {
      sockaddr_storage storage{};
      socklen_t length = 0;

      inline static NetworkAddress ipv4(const in_addr& host, std::uint16_t port = 0) noexcept {
        sockaddr_in address{};

#if defined(__APPLE__)
        address.sin_len = sizeof(address);
#endif
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        address.sin_addr = host;
        return of(address);
      }

      inline static NetworkAddress ipv6(const in6_addr& host, std::uint16_t port = 0) noexcept {
        sockaddr_in6 address{};

#if defined(__APPLE__)
        address.sin6_len = sizeof(address);
#endif
        address.sin6_family = AF_INET6;
        address.sin6_port = htons(port);
        address.sin6_addr = host;
        return of(address);
      }

      inline static std::optional<NetworkAddress> copy(const sockaddr* source, socklen_t size) noexcept {
        if (source == nullptr || (source->sa_family != AF_INET && source->sa_family != AF_INET6)) {
          return std::nullopt;
        }

        const auto expected = source->sa_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6);
        if (size < expected) {
          return std::nullopt;
        }

        NetworkAddress address;

        address.length = static_cast<socklen_t>(expected);
        std::memcpy(&address.storage, source, expected);
        address.setPort(0);
        return address;
      }

      inline void setPort(std::uint16_t port) noexcept {
        if (storage.ss_family == AF_INET) {
          reinterpret_cast<sockaddr_in*>(&storage)->sin_port = htons(port);
        } else if (storage.ss_family == AF_INET6) {
          reinterpret_cast<sockaddr_in6*>(&storage)->sin6_port = htons(port);
        }
      }

      inline const sockaddr* address() const noexcept {
        return reinterpret_cast<const sockaddr*>(&storage);
      }

    private:
      template <typename Address>
      inline static NetworkAddress of(const Address& address) noexcept {
        NetworkAddress result;

        std::memcpy(&result.storage, &address, sizeof(address));
        result.length = sizeof(address);
        return result;
      }
    };

  }
}

// Interface: proxy/socket.cppm
export {
  namespace telar::runtime {

    inline void configureProxySocket(int socket) {
      setCloseOnExec(socket);
      setNonblocking(socket);
      suppressSocketSignals(socket);
    }

    inline FileDescriptor openOriginSocket(int family) {
      FileDescriptor socket{::socket(family, SOCK_STREAM, IPPROTO_TCP)};
      if (!socket) {
        throw SystemError{"Create proxy origin socket"};
      }

      configureProxySocket(socket.get());

      struct Option {
        int level;
        int name;
        int value;
      };

      constexpr int enabled = 1;
      constexpr int idle_seconds = 60;
      constexpr int interval_seconds = 10;
      constexpr int probe_count = 6;
#if defined(__APPLE__)
      constexpr int idle_option = TCP_KEEPALIVE;
#else
      constexpr int idle_option = TCP_KEEPIDLE;
#endif
      constexpr Option options[] = {{SOL_SOCKET, SO_KEEPALIVE, enabled}, {IPPROTO_TCP, idle_option, idle_seconds}, {IPPROTO_TCP, TCP_KEEPINTVL, interval_seconds}, {IPPROTO_TCP, TCP_KEEPCNT, probe_count}};

      for (const auto& option : options) {
        if (::setsockopt(socket.get(), option.level, option.name, &option.value, sizeof(option.value)) != 0) {
          throw SystemError{"Configure proxy origin keepalive"};
        }
      }

      return socket;
    }

  }
}

// Interface: proxy/socket_stream.cppm
export {
  namespace telar::runtime {

    class SocketStream {
    public:
      inline explicit SocketStream(int descriptor) noexcept
          : descriptor_(descriptor) {}

      inline StreamResult read(std::span<std::uint8_t> destination) noexcept {
        const auto received = ::read(descriptor_, destination.data(), destination.size());

        return result(received, StreamReadiness::readable);
      }

      inline StreamResult peek(std::span<std::uint8_t> destination) noexcept {
        return result(::recv(descriptor_, destination.data(), destination.size(), MSG_PEEK), StreamReadiness::readable);
      }

      inline StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
        const auto sent = ::write(descriptor_, bytes.data(), bytes.size());

        return result(sent, StreamReadiness::writable);
      }

      inline void halfClose() noexcept {
        ::shutdown(descriptor_, SHUT_WR);
      }

    private:
      inline static StreamResult result(ssize_t count, StreamReadiness waiting) noexcept {
        if (count > 0) {
          return {StreamResult::State::data, static_cast<std::size_t>(count)};
        }

        if (count == 0) {
          return {StreamResult::State::ended};
        }

        return socketWouldBlock(sys::lastError()) ? StreamResult{StreamResult::State::blocked, 0, waiting} : StreamResult{StreamResult::State::failed};
      }

      int descriptor_;
    };

    static_assert(ByteStream<SocketStream>);
    static_assert(PeekableByteStream<SocketStream>);

  }
}
