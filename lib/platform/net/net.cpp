module telar.platform.net;

import std;
import telar.sys.posix;
import telar.sys.process;
import telar.sys.socket;
import telar.platform.error;
import telar.base.ds;
#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
#endif

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
#ifdef __APPLE__
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

  ds::Option<PeerCredentials> peerCredentials(int socket) noexcept {
#ifdef __APPLE__
    PeerCredentials credentials{};
    if (::getpeereid(socket, &credentials.user, &credentials.group) != 0) {
      return ds::none;
    }

    return credentials;
#else
    ucred credentials{};
    socklen_t length = sizeof(credentials);
    if (::getsockopt(socket, SOL_SOCKET, SO_PEERCRED, &credentials, &length) != 0 || length != sizeof(credentials)) {
      return ds::none;
    }
    return PeerCredentials{credentials.uid, credentials.gid};
#endif
  }

  NetworkAddress NetworkAddress::ipv4(const in_addr& host, std::uint16_t port) noexcept {
    sockaddr_in address{};

#ifdef __APPLE__
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr = host;
    return addressOf(address);
  }

  NetworkAddress NetworkAddress::ipv6(const in6_addr& host, std::uint16_t port) noexcept {
    sockaddr_in6 address{};

#ifdef __APPLE__
    address.sin6_len = sizeof(address);
#endif
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = host;
    return addressOf(address);
  }

  ds::Option<NetworkAddress> NetworkAddress::copy(const sockaddr* source, socklen_t size) noexcept {
    if (source == nullptr || (source->sa_family != AF_INET && source->sa_family != AF_INET6)) {
      return ds::none;
    }

    const auto expected = source->sa_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6);
    if (size < expected) {
      return ds::none;
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
#ifdef __APPLE__
    constexpr int idle_option = TCP_KEEPALIVE;
#else
    constexpr int idle_option = TCP_KEEPIDLE;
#endif
    constexpr Option options[] = {{.level = SOL_SOCKET, .name = SO_KEEPALIVE, .value = enabled}, {.level = IPPROTO_TCP, .name = idle_option, .value = idle_seconds}, {.level = IPPROTO_TCP, .name = TCP_KEEPINTVL, .value = interval_seconds}, {.level = IPPROTO_TCP, .name = TCP_KEEPCNT, .value = probe_count}};

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
      return {.state = StreamResult::State::data, .bytes = static_cast<std::size_t>(count)};
    }

    if (count == 0) {
      return {.state = StreamResult::State::ended};
    }

    return socketWouldBlock(sys::lastError()) ? StreamResult{.state = StreamResult::State::blocked, .bytes = 0, .waiting = waiting} : StreamResult{.state = StreamResult::State::failed};
  }

}
