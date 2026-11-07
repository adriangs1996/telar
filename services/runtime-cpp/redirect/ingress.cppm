module;
#include <cstdlib>
#include <new>

#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <cstddef>

#if (defined(__APPLE__))
#include <cerrno>
#endif
#if (defined(__APPLE__))
#include <net/if.h>
#endif
#if (defined(__APPLE__))
#include <net/if_utun.h>
#endif
#if (defined(__APPLE__))
#include <netinet6/in6_var.h>
#endif
#if (defined(__APPLE__))
#include <sys/ioctl.h>
#endif
#if (defined(__APPLE__))
#include <sys/kern_control.h>
#endif
#if (defined(__APPLE__))
#include <sys/sys_domain.h>
#endif
#if (!(defined(__APPLE__)))
#include <fcntl.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_ether.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/if_tun.h>
#endif
#if (!(defined(__APPLE__)))
#include <net/if.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/ioctl.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/uio.h>
#endif
#include <pcap/pcap.h>
#include <sys/ioctl.h>

#include <cerrno>
#include <csignal>
#include <netinet/tcp.h>
#include <sys/uio.h>

#include <sys/types.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>

#include <pthread.h>
#include <netdb.h>
#include <cstdio>

export module telar.runtime.redirect.ingress;

import std;

export import telar.runtime.proxy.relay_direction;
export import telar.runtime.proxy.authenticate;


export import telar.runtime.platform.git_status;


export import telar.runtime.plugins.protocol;


export import telar.platform;
export import telar.runtime.platform.request_worker;
export import telar.runtime.platform.launch_program;


export import telar.client;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: redirect/target.cppm
export {
namespace telar::runtime::redirect {

struct Target {
  static constexpr std::size_t maximum_targets = 16;
  FixedText<INET6_ADDRSTRLEN> host;
  NetworkAddress endpoint;
  std::uint16_t port = 0;

  inline static ProxyTarget authority(std::string_view text) {
    const auto colon = text.rfind(':');
    if (colon == std::string_view::npos) {
      throw std::invalid_argument{"Redirect target requires a host and port"};
    }
    auto host = text.substr(0, colon);
    if (host.starts_with('[') && host.ends_with(']')) {
      host = host.substr(1, host.size() - 2);
    } else if (host.contains(':')) {
      throw std::invalid_argument{"IPv6 redirect targets require brackets"};
    }
    unsigned port = 0;
    const auto value = text.substr(colon + 1);
    const auto parsed = std::from_chars(value.data(), value.data() + value.size(), port);
    if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || port == 0 || port > UINT16_MAX || !ProxyHostname::validTarget(host)) {
      throw std::invalid_argument{"Invalid redirect target"};
    }
    return {host, static_cast<std::uint16_t>(port)};
  }

  inline static Target parse(std::string_view text) {
    const auto [host, port] = authority(text);
    if (host.size() >= INET6_ADDRSTRLEN) { throw std::invalid_argument{"Redirect target must be a numeric IP address"}; }

    std::array<char, INET6_ADDRSTRLEN> terminated{};
    std::ranges::copy(host, terminated.begin());
    Target result;
    sockaddr_in v4{};
#if defined(__APPLE__)
    v4.sin_len = sizeof(v4);
#endif
    v4.sin_family = AF_INET;
    sockaddr_in6 v6{};
#if defined(__APPLE__)
    v6.sin6_len = sizeof(v6);
#endif
    v6.sin6_family = AF_INET6;
    if (::inet_pton(AF_INET, terminated.data(), &v4.sin_addr) == 1) {
      const auto address = ntohl(v4.sin_addr.s_addr);
      if (address == INADDR_ANY || address == INADDR_BROADCAST || IN_MULTICAST(address)) {
        throw std::invalid_argument{"Redirect target must be unicast"};
      }
      result.endpoint = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&v4), sizeof(v4));
      ::inet_ntop(AF_INET, &v4.sin_addr, terminated.data(), terminated.size());
    } else if (::inet_pton(AF_INET6, terminated.data(), &v6.sin6_addr) == 1) {
      if (IN6_IS_ADDR_UNSPECIFIED(&v6.sin6_addr) || IN6_IS_ADDR_MULTICAST(&v6.sin6_addr) || IN6_IS_ADDR_LINKLOCAL(&v6.sin6_addr) || IN6_IS_ADDR_V4MAPPED(&v6.sin6_addr)) {
        throw std::invalid_argument{"Redirect IPv6 target must be unicast without a scope"};
      }
      result.endpoint = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&v6), sizeof(v6));
      ::inet_ntop(AF_INET6, &v6.sin6_addr, terminated.data(), terminated.size());
    } else {
      throw std::invalid_argument{"Redirect target must be a numeric IP address"};
    }
    result.host.assign(terminated.data());
    result.port = port;
    result.endpoint.setPort(result.port);
    return result;
  }
};

}
}

// Interface: redirect/connection.cppm
export {
namespace telar::runtime::redirect {

struct Connection {
  FileDescriptor child;
  FileDescriptor origin;
  Target target;
  FileDescriptor lifetime{};
};

}
}

// Interface: redirect/discovery.cppm
export {
namespace telar::runtime::redirect {

class Discovery {
public:
  inline Discovery() : injection_(nullptr, &pcap_close) {
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    injection_.reset(pcap_open_live("lo0", 64, 0, 1, error.data()));
    if (!injection_) {
      throw std::runtime_error{error.data()};
    }
    if (pcap_datalink(injection_.get()) != DLT_NULL) {
      throw std::runtime_error{"Loopback injection requires DLT_NULL"};
    }
    const auto descriptor = pcap_fileno(injection_.get());
    setCloseOnExec(descriptor);
    unsigned complete = 1;
    constexpr unsigned long complete_headers = _IOW('B', 117, unsigned int); // Darwin BIOCSHDRCMPLT
    if (::ioctl(descriptor, complete_headers, &complete) != 0) {
      throw SystemError{"Configure complete loopback injection headers"};
    }
    bpf_insn reject = BPF_STMT(BPF_RET | BPF_K, 0);
    bpf_program filter{.bf_len = 1, .bf_insns = &reject};
    if (pcap_setfilter(injection_.get(), &filter) != 0) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

  inline int descriptor() const noexcept { return tunnel_.descriptor(); }
  inline std::string_view name() const noexcept { return tunnel_.name(); }

  inline std::span<Byte> receive(std::span<Byte> bytes) {
    const auto size = ::read(tunnel_.descriptor(), bytes.data(), bytes.size());
    if (size < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return {};
    }
    if (size <= 0) {
      throw SystemError{"Read discovery packet"};
    }
    return bytes.first(static_cast<std::size_t>(size));
  }

  inline void inject(std::span<Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      throw std::invalid_argument{"Truncated discovery frame"};
    }
    std::uint32_t family;
    std::memcpy(&family, frame.data(), sizeof(family));
    family = ntohl(family);
    std::memcpy(frame.data(), &family, sizeof(family));
    // utun uses network byte order; DLT_NULL requires the host-order family.
    const auto count = pcap_inject(injection_.get(), frame.data(), frame.size());
    if (count < 0 || static_cast<std::size_t>(count) != frame.size()) {
      throw std::runtime_error{pcap_geterr(injection_.get())};
    }
  }

private:
  PrivateTunnel tunnel_;
  std::unique_ptr<pcap_t, decltype(&pcap_close)> injection_;
};

}
}

// Interface: redirect/protocol.cppm
export {
namespace telar::runtime::redirect {

inline constexpr std::string_view socket_suffix = ".redirect";
enum class Kind : Byte { monitor = 1, connection = 2 };
enum class MonitorState : Byte { idle, starting, active, stopping, cleanup_required };
enum class MonitorUpdate : Byte { active = 1, stopped = 2 };
inline constexpr Byte stop_request = 1;

class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31524454;
  static constexpr std::size_t frame_bytes = 128;
  static constexpr std::size_t descriptor_count = 2;
  static constexpr std::size_t header_bytes = sizeof(std::uint32_t) + sizeof(Byte) + sizeof(std::uint32_t);
  static constexpr std::size_t tail_bytes = sizeof(std::uint16_t);

  inline static std::span<const Byte> encode(std::span<Byte> output, Kind kind, const Target &target) {
    plugins::FrameWriter writer{output};
    writer.integer(magic);
    writer.tag(kind);
    writer.text(target.host.view());
    writer.integer(target.port);
    return writer.finish();
  }

  inline static void send(int channel, const Connection &connection) {
    std::array<Byte, frame_bytes> output;
    const auto frame = encode(output, Kind::connection, connection.target);
    iovec vector{.iov_base = const_cast<Byte *>(frame.data()), .iov_len = frame.size()};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(descriptor_count * sizeof(int))> control{};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    auto *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(descriptor_count * sizeof(int));
    const std::array descriptors{connection.child.get(), connection.origin.get()};
    std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(descriptors));
    ssize_t written;
    do {
      written = ::sendmsg(channel, &message, 0);
    } while (written < 0 && errno == EINTR);
    if (written <= 0) {
      throw SystemError{"Transfer redirected sockets"};
    }
    auto remaining = frame.subspan(static_cast<std::size_t>(written));
    while (!remaining.empty()) {
      written = ::send(channel, remaining.data(), remaining.size(), 0);
      if (written < 0 && errno == EINTR) {
        continue;
      }
      if (written <= 0) {
        throw SystemError{"Finish redirected socket transfer"};
      }
      remaining = remaining.subspan(static_cast<std::size_t>(written));
    }
    ::shutdown(channel, SHUT_WR);
  }
};

// Descriptors are adopted immediately, including on malformed/truncated frames.
// A failed decode therefore closes every received descriptor.
class Incoming {
public:
  inline bool receive(int channel) {
    iovec vector{.iov_base = bytes_.data() + size_, .iov_len = bytes_.size() - size_};
    alignas(cmsghdr) std::array<Byte, CMSG_SPACE(8 * sizeof(int))> control{};
    msghdr message{};
    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.data();
    message.msg_controllen = control.size();
    const auto count = ::recvmsg(channel, &message, 0);
    if (count < 0) {
      if (socketWouldBlock(errno)) {
        return false;
      }
      throw SystemError{"Receive redirected sockets"};
    }
    bool invalid = (message.msg_flags & MSG_CTRUNC) != 0;
    for (auto *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
      if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS || header->cmsg_len < CMSG_LEN(0)) {
        invalid = true;
        continue;
      }
      const auto descriptors = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
      for (std::size_t index = 0; index < descriptors; ++index) {
        int raw;
        std::memcpy(&raw, CMSG_DATA(header) + index * sizeof(int), sizeof(raw));
        FileDescriptor received{raw};
        if (received_ == sockets_.size()) {
          invalid = true;
        } else {
          sockets_[received_++] = std::move(received);
        }
      }
    }
    if (invalid) {
      throw EncodingError{"Invalid redirected socket descriptors"};
    }
    for (std::size_t index = 0; index < received_; ++index) {
      setCloseOnExec(sockets_[index].get());
    }
    if (count > 0 && size_ + static_cast<std::size_t>(count) == bytes_.size()) {
      throw EncodingError{"Invalid redirect frame"};
    }
    if (count > 0) {
      size_ += static_cast<std::size_t>(count);
      if (size_ < Protocol::header_bytes) {
        return false;
      }
      auto length = std::span<const Byte>{bytes_}.first(size_).subspan(sizeof(std::uint32_t) + sizeof(Byte));
      const auto host_bytes = LittleEndian<std::uint32_t>::decode(length);
      const auto expected = Protocol::header_bytes + static_cast<std::size_t>(host_bytes) + Protocol::tail_bytes;
      if (expected > bytes_.size() || size_ > expected) {
        throw EncodingError{"Invalid redirect frame length"};
      }
      return size_ == expected;
    }
    throw EncodingError{"Truncated redirect frame"};
  }

  inline Kind kind() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    if (reader.integer<std::uint32_t>() != Protocol::magic) {
      throw EncodingError{"Incompatible redirect protocol"};
    }
    const auto kind = reader.tag(Kind::connection);
    if (kind != Kind::monitor && kind != Kind::connection) {
      throw EncodingError{"Unknown redirect operation"};
    }
    return kind;
  }

  inline void validateMonitor() const {
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    if (!reader.text().empty() || reader.integer<std::uint16_t>() != 0 || received_ != 0) {
      throw EncodingError{"A redirect monitor cannot carry sockets or a target"};
    }
    reader.finish();
  }

  inline Connection take() {
    if (kind() != Kind::connection || received_ != Protocol::descriptor_count) {
      throw EncodingError{"A redirected connection requires two sockets"};
    }
    plugins::FrameReader reader{std::span{bytes_}.first(size_)};
    reader.integer<std::uint32_t>();
    reader.integer<Byte>();
    const auto host = reader.text();
    const auto port = reader.integer<std::uint16_t>();
    reader.finish();
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) {
      throw EncodingError{"Invalid redirected host"};
    }
    std::array<char, Protocol::frame_bytes> address{};
    const auto count = std::snprintf(address.data(), address.size(), host.contains(':') ? "[%.*s]:%u" : "%.*s:%u", static_cast<int>(host.size()), host.data(), port);
    if (count < 0 || static_cast<std::size_t>(count) >= address.size()) {
      throw EncodingError{"Invalid redirect destination"};
    }
    auto target = Target::parse(address.data());
    for (const auto &socket : sockets_) {
      int type = 0;
      socklen_t length = sizeof(type);
      sockaddr_storage peer{};
      socklen_t peer_length = sizeof(peer);
      if (::getsockopt(socket.get(), SOL_SOCKET, SO_TYPE, &type, &length) != 0 || type != SOCK_STREAM || ::getpeername(socket.get(), reinterpret_cast<sockaddr *>(&peer), &peer_length) != 0 || peer.ss_family != target.endpoint.storage.ss_family) {
        throw EncodingError{"Redirect handoff requires connected TCP sockets"};
      }
      configureProxySocket(socket.get());
    }
    sockaddr_storage actual{};
    socklen_t size = sizeof(actual);
    if (::getpeername(sockets_[1].get(), reinterpret_cast<sockaddr *>(&actual), &size) != 0) {
      throw SystemError{"Inspect redirected origin"};
    }
    const bool matches = actual.ss_family == AF_INET
        ? reinterpret_cast<const sockaddr_in *>(&actual)->sin_port == htons(target.port) && reinterpret_cast<const sockaddr_in *>(&actual)->sin_addr.s_addr == reinterpret_cast<const sockaddr_in *>(&target.endpoint.storage)->sin_addr.s_addr
        : reinterpret_cast<const sockaddr_in6 *>(&actual)->sin6_port == htons(target.port) && std::memcmp(&reinterpret_cast<const sockaddr_in6 *>(&actual)->sin6_addr, &reinterpret_cast<const sockaddr_in6 *>(&target.endpoint.storage)->sin6_addr, sizeof(in6_addr)) == 0;
    if (!matches) {
      throw EncodingError{"Redirected origin does not match its original destination"};
    }
    return {.child = std::move(sockets_[0]), .origin = std::move(sockets_[1]), .target = target};
  }

private:
  std::array<Byte, Protocol::frame_bytes> bytes_{};
  std::array<FileDescriptor, Protocol::descriptor_count> sockets_;
  std::size_t size_ = 0;
  std::size_t received_ = 0;
};

}
}

// Interface: redirect/ingress.cppm
export {
namespace telar::runtime::redirect {

struct PrivilegedPeer {
  inline static bool allows(uid_t uid) noexcept { return uid == 0; }
};

template <typename Sink, typename PeerPolicy = PrivilegedPeer>
class Ingress {
  struct Peer {
    FileDescriptor socket;
    Incoming incoming;
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    bool monitor = false;
  };

public:
  inline explicit Ingress(std::string_view path, Sink &sink) : listener_(path), sink_(sink), worker_([this] { run(); }) {}

  inline ~Ingress() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    worker_.join();
  }

  Ingress(const Ingress &) = delete;
  Ingress &operator=(const Ingress &) = delete;

  inline MonitorState status() const noexcept { return status_.load(std::memory_order_acquire); }
  inline void stop() noexcept {
    stop_requested_.store(true, std::memory_order_release);
    wake_.notify();
  }

private:
  inline void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar redirect ingress: %s\n", error.what());
      }
    }
  }

  inline void step() {
    std::array<pollfd, maximum_peers + 2> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      descriptors[index + 2] = {.fd = peers_[index] ? peers_[index]->socket.get() : -1, .events = POLLIN, .revents = 0};
    }
    constexpr int poll_ms = 100;
    if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
      throw SystemError{"Poll redirected socket ingress"};
    }
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    if (descriptors[1].revents & POLLIN) { wake_.drain(); }
    if (stop_requested_.exchange(false, std::memory_order_acq_rel)) {
      for (auto &peer : peers_) {
        if (peer && peer->monitor) {
          status_.store(MonitorState::stopping, std::memory_order_release);
          if (::send(peer->socket.get(), &stop_request, 1, 0) != 1) {
            status_.store(MonitorState::cleanup_required, std::memory_order_release);
            peer.reset();
          }
        }
      }
    }
    if (descriptors[0].revents & POLLIN) {
      accept();
    }
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) {
        continue;
      }
      const auto readiness = descriptors[index + 2].revents;
      bool close = readiness & (POLLERR | POLLNVAL);
      try {
        if (!peer->monitor && (readiness & (POLLIN | POLLHUP)) && peer->incoming.receive(peer->socket.get())) {
          if (peer->incoming.kind() == Kind::monitor) {
            peer->incoming.validateMonitor();
            if (std::ranges::any_of(peers_, [](const auto &candidate) { return candidate && candidate->monitor; })) {
              throw EncodingError{"A redirect helper already owns this endpoint"};
            }
            peer->monitor = true;
            status_.store(MonitorState::starting, std::memory_order_release);
            std::array<Byte, sizeof(std::uint32_t)> reply;
            plugins::FrameWriter writer{reply};
            writer.integer(static_cast<std::uint32_t>(::geteuid()));
            close = ::send(peer->socket.get(), reply.data(), reply.size(), 0) != static_cast<ssize_t>(reply.size());
          } else {
            auto connection = peer->incoming.take();
            connection.lifetime.reset(::fcntl(peer->socket.get(), F_DUPFD_CLOEXEC, 0));
            if (!connection.lifetime) {
              throw SystemError{"Keep redirected connection lifetime"};
            }
            const Byte admitted = sink_.adopt(std::move(connection)) ? 1 : 0;
            ::send(peer->socket.get(), &admitted, sizeof(admitted), 0);
            close = true;
          }
        } else if (peer->monitor && (readiness & (POLLIN | POLLHUP))) {
          close = advanceMonitor(*peer);
        }
      } catch (const std::exception &) {
        close = true;
      }
      if (close || (!peer->monitor && std::chrono::steady_clock::now() >= peer->deadline)) {
        if (peer->monitor) { status_.store(MonitorState::cleanup_required, std::memory_order_release); }
        peer.reset();
      }
    }
  }

  inline bool advanceMonitor(Peer &peer) {
    for (std::size_t count = 0; count < 3; ++count) {
      Byte update;
      const auto received = ::recv(peer.socket.get(), &update, 1, 0);
      if (received < 0 && socketWouldBlock(errno)) { return false; }
      if (received != 1) { return true; }
      if (update == static_cast<Byte>(MonitorUpdate::active) && (status() == MonitorState::starting || status() == MonitorState::stopping)) {
        if (status() == MonitorState::starting) { status_.store(MonitorState::active, std::memory_order_release); }
      } else if (update == static_cast<Byte>(MonitorUpdate::stopped)) {
        status_.store(MonitorState::idle, std::memory_order_release);
        peer.monitor = false;
        return true;
      } else { return true; }
    }
    return true;
  }

  inline void accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }
    const auto credentials = peerCredentials(socket.get());
    if (!credentials || !PeerPolicy::allows(credentials->user)) {
      return;
    }
    for (auto &peer : peers_) {
      if (!peer) {
        peer.emplace();
        peer->socket = std::move(socket);
        return;
      }
    }
  }

  static constexpr std::size_t maximum_peers = 32;
  LocalListener listener_;
  Sink &sink_;
  CompletionSignal wake_;
  std::array<std::optional<Peer>, maximum_peers> peers_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> stop_requested_{false};
  std::atomic<MonitorState> status_{MonitorState::idle};
  std::thread worker_;
};

}
}

// Interface: redirect/selection.cppm
export {
namespace telar::runtime::redirect {

template <HostnameResolver Resolver = SystemNameResolver>
class Selection {
  using Resolutions = NameResolutions<Resolver>;
  using Clock = std::chrono::steady_clock;
  struct Pending {
    std::optional<typename Resolutions::Ticket> ticket;
    std::uint16_t port = 0;
  };

public:
  static constexpr std::size_t maximum_argument_bytes = INET6_ADDRSTRLEN + 8;

  inline explicit Selection(std::span<const std::string_view> input, const std::atomic<bool> &cancelled, Clock::time_point deadline) {
    if (input.empty() || input.size() > Target::maximum_targets) { throw std::invalid_argument{"Redirect requires 1..16 destinations"}; }
    std::array<Pending, Target::maximum_targets> pending;
    std::array<std::optional<Target>, Target::maximum_targets> numeric_targets;
    CompletionSignal signal;
    typename Resolutions::Notifications notifications{signal};
    std::size_t remaining = 0;
    for (std::size_t index = 0; index < input.size(); ++index) {
      check(cancelled, deadline);
      const auto authority = Target::authority(input[index]);
      const auto host = authority.hostname;
      const bool numeric = input[index].starts_with('[') || host.contains(':') || std::ranges::all_of(host, [](char byte) { return (byte >= '0' && byte <= '9') || byte == '.'; });
      if (numeric) {
        const auto target = Target::parse(input[index]);
        if (std::ranges::any_of(std::span{numeric_targets}.first(index), [&](const auto &other) { return other && other->host.view() == target.host.view() && other->port == target.port; })) { throw std::invalid_argument{"Duplicate redirect destination"}; }
        numeric_targets[index] = target;
        append(target);
        continue;
      }
      pending[index].port = authority.port;
      pending[index].ticket = Resolutions::request(host);
      if (!pending[index].ticket) { throw SystemError{"Redirect hostname resolver is at capacity", EAGAIN}; }
      ++remaining;
    }

    while (remaining != 0) {
      check(cancelled, deadline);
      for (auto &item : pending) {
        if (!item.ticket) { continue; }
        typename Resolutions::Result result;
        if (!item.ticket->collect(result)) { continue; }
        if (result.summary.error != 0 || result.summary.found == 0) { throw std::invalid_argument{"Redirect hostname resolution failed"}; }
        if (result.summary.found > result.addresses.size()) { throw std::invalid_argument{"Redirect hostname has too many addresses"}; }
        for (const auto &address : std::span{result.addresses}.first(result.summary.found)) { append(address, item.port); }
        item.ticket.reset();
        --remaining;
      }
      if (remaining != 0) {
        pollfd descriptor{signal.descriptor(), POLLIN, 0};
        if (::poll(&descriptor, 1, 20) < 0 && errno != EINTR) { throw SystemError{"Wait for redirect hostname resolution"}; }
        signal.drain();
      }
    }
  }

  inline std::span<const Target> targets() const noexcept { return std::span{targets_}.first(count_); }
  inline std::string_view argument(std::size_t index) const noexcept { return arguments_[index].view(); }

private:
  inline static void check(const std::atomic<bool> &cancelled, Clock::time_point deadline) {
    if (cancelled) { throw RequestError{FailureCode::invalid_request, "Redirect selection cancelled"}; }
    if (Clock::now() >= deadline) { throw RequestError{FailureCode::resource_limit, "Redirect hostname resolution deadline exceeded"}; }
  }

  inline void append(const NetworkAddress &address, std::uint16_t port) {
    const auto family = address.storage.ss_family;
    std::array<char, INET6_ADDRSTRLEN> host{};
    if (family == AF_INET) {
      if (address.length != sizeof(sockaddr_in) || !::inet_ntop(AF_INET, &reinterpret_cast<const sockaddr_in *>(&address.storage)->sin_addr, host.data(), host.size())) { throw std::invalid_argument{"Invalid resolved IPv4 destination"}; }
    } else if (family == AF_INET6) {
      const auto &v6 = *reinterpret_cast<const sockaddr_in6 *>(&address.storage);
      if (address.length != sizeof(sockaddr_in6) || v6.sin6_scope_id != 0 || !::inet_ntop(AF_INET6, &v6.sin6_addr, host.data(), host.size())) { throw std::invalid_argument{"Invalid resolved IPv6 destination"}; }
    } else { throw std::invalid_argument{"Resolved destination must use IP"}; }
    std::array<char, maximum_argument_bytes> text{};
    std::snprintf(text.data(), text.size(), family == AF_INET6 ? "[%s]:%u" : "%s:%u", host.data(), static_cast<unsigned>(port));
    append(Target::parse(text.data()));
  }

  inline void append(const Target &target) {
    if (std::ranges::any_of(targets(), [&](const auto &other) { return other.host.view() == target.host.view() && other.port == target.port; })) { return; }
    if (count_ == targets_.size()) { throw std::invalid_argument{"Resolved redirect selection exceeds 16 destinations"}; }
    std::array<char, maximum_argument_bytes> argument{};
    const auto host = target.host.view();
    std::snprintf(argument.data(), argument.size(), target.endpoint.storage.ss_family == AF_INET6 ? "[%.*s]:%u" : "%.*s:%u", static_cast<int>(host.size()), host.data(), static_cast<unsigned>(target.port));
    targets_[count_] = target;
    arguments_[count_++].assign(argument.data());
  }

  std::array<Target, Target::maximum_targets> targets_;
  std::array<FixedText<maximum_argument_bytes>, Target::maximum_targets> arguments_;
  std::size_t count_ = 0;
};

}
}
