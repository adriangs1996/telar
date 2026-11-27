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

      // A family's sockaddr into sockaddr_storage, which holds any.
#pragma clang unsafe_buffer_usage begin
      std::memcpy(&result.storage, &address, sizeof(address));
#pragma clang unsafe_buffer_usage end
      result.length = sizeof(address);
      return result;
    }

  }

  bool socketWouldBlock(int error) noexcept {
    // POSIX lets EWOULDBLOCK differ from EAGAIN, though Linux and macOS spell one error twice.
    constexpr bool distinct_would_block = EWOULDBLOCK != EAGAIN;

    return error == EAGAIN || error == EINTR || (distinct_would_block && error == EWOULDBLOCK);
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

  bool socketSignalsSuppressed(int descriptor) noexcept {
#ifdef __APPLE__
    return ::fcntl(descriptor, F_GETNOSIGPIPE) == 1; // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
#else
    (void)descriptor;
    struct sigaction current{};

    return ::sigaction(SIGPIPE, nullptr, &current) == 0 && sys::signalHandler(current) == SIG_IGN;
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
    // A family's sockaddr, whose size `size` covers, into sockaddr_storage.
#pragma clang unsafe_buffer_usage begin
    std::memcpy(&address.storage, source, expected);
#pragma clang unsafe_buffer_usage end
    address.setPort(0);
    return address;
  }

  void NetworkAddress::setPort(std::uint16_t port) noexcept {
    if (storage.ss_family == AF_INET) {
      reinterpret_cast<sockaddr_in*>(&storage)->sin_port = htons(port); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    } else if (storage.ss_family == AF_INET6) {
      reinterpret_cast<sockaddr_in6*>(&storage)->sin6_port = htons(port); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    }
  }

  const sockaddr* NetworkAddress::address() const noexcept {
    return reinterpret_cast<const sockaddr*>(&storage); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
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
    constexpr ds::Array options{
        Option{.level = SOL_SOCKET, .name = SO_KEEPALIVE, .value = enabled},
        Option{.level = IPPROTO_TCP, .name = idle_option, .value = idle_seconds},
        Option{.level = IPPROTO_TCP, .name = TCP_KEEPINTVL, .value = interval_seconds},
        Option{.level = IPPROTO_TCP, .name = TCP_KEEPCNT, .value = probe_count},
    };

    for (const auto& option : options) {
      if (::setsockopt(socket.get(), option.level, option.name, &option.value, sizeof(option.value)) != 0) {
        throw SystemError{"Configure proxy origin keepalive"};
      }
    }

    return socket;
  }

  SocketStream::SocketStream(int descriptor) noexcept
      : descriptor_(descriptor) {}

  StreamResult SocketStream::read(std::span<std::uint8_t> destination) noexcept { // NOLINT(readability-make-member-function-const): it reads or writes the socket, a mutation tbc sees through the descriptor
    const auto received = ::read(descriptor_, destination.data(), destination.size());

    return result(received, StreamReadiness::readable);
  }

  StreamResult SocketStream::peek(std::span<std::uint8_t> destination) noexcept { // NOLINT(readability-make-member-function-const): it reads or writes the socket, a mutation tbc sees through the descriptor
    return result(::recv(descriptor_, destination.data(), destination.size(), MSG_PEEK), StreamReadiness::readable);
  }

  StreamResult SocketStream::write(std::span<const std::uint8_t> bytes) noexcept { // NOLINT(readability-make-member-function-const): it reads or writes the socket, a mutation tbc sees through the descriptor
    const auto sent = ::write(descriptor_, bytes.data(), bytes.size());

    return result(sent, StreamReadiness::writable);
  }

  void SocketStream::halfClose() noexcept { // NOLINT(readability-make-member-function-const): it reads or writes the socket, a mutation tbc sees through the descriptor
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
