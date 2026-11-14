module;
#include <cerrno>
#include <csignal>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

module telar.platform.net;

import std;

namespace telar::runtime {
  namespace {

    template <typename Address>
    NetworkAddress addressOf(const Address& address) noexcept {
      NetworkAddress result;

      std::memcpy(&result.storage, &address, sizeof(address));
      result.length = sizeof(address);
      return result;
    }

  }

  bool socketWouldBlock(int error) noexcept {
    return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
  }

  void suppressSocketSignals(int descriptor) {
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

  std::optional<PeerCredentials> peerCredentials(int socket) noexcept {
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

  NetworkAddress NetworkAddress::ipv4(const in_addr& host, std::uint16_t port) noexcept {
    sockaddr_in address{};

#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr = host;
    return addressOf(address);
  }

  NetworkAddress NetworkAddress::ipv6(const in6_addr& host, std::uint16_t port) noexcept {
    sockaddr_in6 address{};

#if defined(__APPLE__)
    address.sin6_len = sizeof(address);
#endif
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = host;
    return addressOf(address);
  }

  std::optional<NetworkAddress> NetworkAddress::copy(const sockaddr* source, socklen_t size) noexcept {
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

  void NetworkAddress::setPort(std::uint16_t port) noexcept {
    if (storage.ss_family == AF_INET) {
      reinterpret_cast<sockaddr_in*>(&storage)->sin_port = htons(port);
    } else if (storage.ss_family == AF_INET6) {
      reinterpret_cast<sockaddr_in6*>(&storage)->sin6_port = htons(port);
    }
  }

  const sockaddr* NetworkAddress::address() const noexcept {
    return reinterpret_cast<const sockaddr*>(&storage);
  }

  void configureProxySocket(int socket) {
    setCloseOnExec(socket);
    setNonblocking(socket);
    suppressSocketSignals(socket);
  }

  FileDescriptor openOriginSocket(int family) {
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

  SocketStream::SocketStream(int descriptor) noexcept
      : descriptor_(descriptor) {}

  StreamResult SocketStream::read(std::span<std::uint8_t> destination) noexcept {
    const auto received = ::read(descriptor_, destination.data(), destination.size());

    return result(received, StreamReadiness::readable);
  }

  StreamResult SocketStream::peek(std::span<std::uint8_t> destination) noexcept {
    return result(::recv(descriptor_, destination.data(), destination.size(), MSG_PEEK), StreamReadiness::readable);
  }

  StreamResult SocketStream::write(std::span<const std::uint8_t> bytes) noexcept {
    const auto sent = ::write(descriptor_, bytes.data(), bytes.size());

    return result(sent, StreamReadiness::writable);
  }

  void SocketStream::halfClose() noexcept {
    ::shutdown(descriptor_, SHUT_WR);
  }

  StreamResult SocketStream::result(ssize_t count, StreamReadiness waiting) noexcept {
    if (count > 0) {
      return {StreamResult::State::data, static_cast<std::size_t>(count)};
    }

    if (count == 0) {
      return {StreamResult::State::ended};
    }

    return socketWouldBlock(sys::lastError()) ? StreamResult{StreamResult::State::blocked, 0, waiting} : StreamResult{StreamResult::State::failed};
  }

}
