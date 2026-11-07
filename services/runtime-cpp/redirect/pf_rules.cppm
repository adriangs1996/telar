module;
#include <concepts>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <limits>
#include <unistd.h>
#include <utility>
#include <cstdlib>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#include <stdexcept>
#include <string_view>

#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <cstddef>
#include <charconv>
#include <span>

#include <cerrno>
#include <exception>
#include <fcntl.h>
#include <sys/ioctl.h>

#include <chrono>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <poll.h>

export module telar.runtime.redirect.pf_rules;

export import telar.runtime.redirect.direction;

export import telar.runtime.redirect.ingress;


export import telar.platform;


export import telar.plugins;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: redirect/flow_key.cppm
export {
namespace telar::runtime::redirect {

struct FlowKey {
  Target source;
  Target destination;

  inline bool matches(const FlowKey &other) const noexcept {
    return same(source, other.source) && same(destination, other.destination);
  }

  inline static bool same(const Target &left, const Target &right) noexcept {
    return left.port == right.port && left.host.view() == right.host.view();
  }

  inline static std::optional<FlowKey> syn(std::span<const Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      return std::nullopt;
    }
    std::uint32_t encoded_family;
    std::memcpy(&encoded_family, frame.data(), sizeof(encoded_family));
    const auto family = ntohl(encoded_family);
    const auto packet = frame.subspan(sizeof(encoded_family));
    std::size_t offset;
    std::size_t source;
    std::size_t destination;
    if (family == AF_INET && packet.size() >= 20 && packet[0] >> 4 == 4) {
      offset = (packet[0] & 0x0f) * 4;
      if (offset < 20 || offset > packet.size() || number(packet, 2) != packet.size() || (number(packet, 6) & 0x3fff) != 0 || packet[9] != IPPROTO_TCP) {
        return std::nullopt;
      }
      source = 12;
      destination = 16;
    } else if (family == AF_INET6 && packet.size() >= 40 && packet[0] >> 4 == 6) {
      if (number(packet, 4) + 40 != packet.size()) {
        return std::nullopt;
      }
      offset = 40;
      unsigned next = packet[6];
      for (std::size_t count = 0; next != IPPROTO_TCP; ++count) {
        if (count == 8 || offset + 2 > packet.size() || (next != IPPROTO_HOPOPTS && next != IPPROTO_ROUTING && next != IPPROTO_DSTOPTS && next != IPPROTO_AH)) {
          return std::nullopt;
        }
        const auto length = next == IPPROTO_AH ? (packet[offset + 1] + 2) * 4 : (packet[offset + 1] + 1) * 8;
        next = packet[offset];
        offset += static_cast<std::size_t>(length);
      }
      source = 8;
      destination = 24;
    } else {
      return std::nullopt;
    }
    if (offset + 20 > packet.size() || (packet[offset + 13] & 0x17) != 0x02) {
      return std::nullopt;
    }
    const auto header = static_cast<std::size_t>(packet[offset + 12] >> 4) * 4;
    if (header < 20 || header > packet.size() - offset) {
      return std::nullopt;
    }
    try {
      return FlowKey{.source = endpoint(family, packet.subspan(source), number(packet, offset)), .destination = endpoint(family, packet.subspan(destination), number(packet, offset + 2))};
    } catch (const std::invalid_argument &) {
      return std::nullopt;
    }
  }

private:
  inline static std::uint16_t number(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(static_cast<unsigned>(bytes[offset]) << 8 | bytes[offset + 1]);
  }

  inline static Target endpoint(unsigned family, std::span<const Byte> bytes, std::uint16_t port) {
    std::array<char, INET6_ADDRSTRLEN> host{};
    if (::inet_ntop(static_cast<int>(family), bytes.data(), host.data(), host.size()) == nullptr) {
      throw std::invalid_argument{"Invalid discovery address"};
    }
    std::array<char, INET6_ADDRSTRLEN + 16> text{};
    std::snprintf(text.data(), text.size(), family == AF_INET6 ? "[%s]:%u" : "%s:%u", host.data(), port);
    return Target::parse(text.data());
  }
};

}
}

// Interface: redirect/nat_lookup.cppm
export {
namespace telar::runtime::redirect {

class NatLookup {
  // Darwin pfioc_natlook, including four 32-bit pf_state_xport unions.
  struct Request {
    std::array<Byte, 16> source{};
    std::array<Byte, 16> destination{};
    std::array<Byte, 16> translated_source{};
    std::array<Byte, 16> translated_destination{};
    std::uint32_t source_port = 0;
    std::uint32_t destination_port = 0;
    std::uint32_t translated_source_port = 0;
    std::uint32_t translated_destination_port = 0;
    std::uint8_t family = 0;
    std::uint8_t protocol = IPPROTO_TCP;
    std::uint8_t variant = 0;
    std::uint8_t direction = 2; // PF_OUT: reverse lookup from accepted socket.
  };
  static_assert(sizeof(Request) == 84);
  static constexpr unsigned long lookup = _IOWR('D', 23, Request);

public:
  inline NatLookup() : device_(::open("/dev/pf", O_RDWR | O_CLOEXEC | O_NOFOLLOW)) {
    if (!device_) { throw SystemError{"Open redirect NAT lookup"}; }
  }

  inline bool matches(int socket, const FlowKey &flow) const {
    Request request;
    sockaddr_storage peer{};
    sockaddr_storage local{};
    socklen_t size = sizeof(peer);
    if (::getpeername(socket, reinterpret_cast<sockaddr *>(&peer), &size) != 0) { return false; }
    size = sizeof(local);
    if (::getsockname(socket, reinterpret_cast<sockaddr *>(&local), &size) != 0 || peer.ss_family != local.ss_family || peer.ss_family != flow.source.endpoint.storage.ss_family) { return false; }
    request.family = peer.ss_family;
    address(peer, request.source, request.source_port);
    address(local, request.destination, request.destination_port);
    if (::ioctl(device_.get(), lookup, &request) != 0) { return false; }
    std::array<Byte, 16> expected{};
    std::uint32_t port = 0;
    address(flow.destination.endpoint.storage, expected, port);
    return expected == request.translated_destination && port == request.translated_destination_port;
  }

  inline static bool peerMatches(int socket, const FlowKey &flow) {
    sockaddr_storage peer{};
    socklen_t size = sizeof(peer);
    if (::getpeername(socket, reinterpret_cast<sockaddr *>(&peer), &size) != 0 || peer.ss_family != flow.source.endpoint.storage.ss_family) { return false; }
    std::array<Byte, 16> actual{};
    std::array<Byte, 16> expected{};
    std::uint32_t actual_port = 0;
    std::uint32_t expected_port = 0;
    address(peer, actual, actual_port);
    address(flow.source.endpoint.storage, expected, expected_port);
    return actual == expected && actual_port == expected_port;
  }

private:
  inline static void address(const sockaddr_storage &socket, std::span<Byte, 16> bytes, std::uint32_t &port) {
    if (socket.ss_family == AF_INET) {
      const auto &value = reinterpret_cast<const sockaddr_in &>(socket);
      std::memcpy(bytes.data(), &value.sin_addr, sizeof(value.sin_addr));
      port = value.sin_port;
    } else {
      const auto &value = reinterpret_cast<const sockaddr_in6 &>(socket);
      std::memcpy(bytes.data(), &value.sin6_addr, sizeof(value.sin6_addr));
      port = value.sin6_port;
    }
  }

  FileDescriptor device_;
};

}
}

// Interface: redirect/route_path.cppm
export {
namespace telar::runtime::redirect {

struct RoutePath {
  FixedText<IFNAMSIZ> interface;
  FixedText<INET6_ADDRSTRLEN> gateway;
  unsigned index = 0;

  inline static RoutePath lookup(const Target &target, unsigned scope = 0) {
    if (scope > UINT16_MAX) { throw std::invalid_argument{"Invalid route interface scope"}; }
    FileDescriptor socket{::socket(PF_ROUTE, SOCK_RAW, 0)};
    if (!socket) { throw SystemError{"Open route lookup socket"}; }
    setCloseOnExec(socket.get());
    setNonblocking(socket.get());
    rt_msghdr message{};
    message.rtm_msglen = sizeof(message) + aligned(target.endpoint.length);
    message.rtm_version = RTM_VERSION;
    message.rtm_type = RTM_GET;
    message.rtm_index = static_cast<unsigned short>(scope);
    message.rtm_flags = RTF_UP | RTF_HOST | (scope ? RTF_IFSCOPE : 0);
    message.rtm_addrs = RTA_DST | RTA_IFP;
    message.rtm_pid = ::getpid();
    message.rtm_seq = 1;
    std::array<Byte, maximum_message_bytes> bytes{};
    std::memcpy(bytes.data(), &message, sizeof(message));
    auto destination = target.endpoint;
    destination.setPort(0);
    std::memcpy(bytes.data() + sizeof(message), destination.address(), destination.length);
    sockaddr_dl interface{};
    interface.sdl_len = sizeof(interface);
    interface.sdl_family = AF_LINK;
    interface.sdl_index = static_cast<unsigned short>(scope);
    std::memcpy(bytes.data() + message.rtm_msglen, &interface, sizeof(interface));
    message.rtm_msglen += aligned(sizeof(interface));
    std::memcpy(bytes.data(), &message, sizeof(message));
    ssize_t sent;
    do { sent = ::write(socket.get(), bytes.data(), message.rtm_msglen); } while (sent < 0 && errno == EINTR);
    if (sent != message.rtm_msglen) { throw SystemError{"Request original route"}; }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{500};
    while (std::chrono::steady_clock::now() < deadline) {
      pollfd ready{socket.get(), POLLIN, 0};
      if (::poll(&ready, 1, 25) < 0 && errno != EINTR) { throw SystemError{"Wait for original route"}; }
      if (!(ready.revents & POLLIN)) { continue; }
      const auto received = ::read(socket.get(), bytes.data(), bytes.size());
      if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) { continue; }
      if (received < static_cast<ssize_t>(sizeof(message))) { throw SystemError{"Read original route", EIO}; }
      rt_msghdr reply;
      std::memcpy(&reply, bytes.data(), sizeof(reply));
      if (reply.rtm_pid != message.rtm_pid || reply.rtm_seq != message.rtm_seq || reply.rtm_type != RTM_GET) { continue; }
      auto result = decode(std::span<const Byte>{bytes}.first(received), target);
      if (scope != 0 && result.index != scope) { throw SystemError{"Original route changed interface", ENETUNREACH}; }
      return result;
    }
    throw SystemError{"Original route lookup timed out", ETIMEDOUT};
  }

  inline static RoutePath decode(std::span<const Byte> bytes, const Target &target) {
    if (bytes.size() < sizeof(rt_msghdr)) { throw EncodingError{"Truncated route reply"}; }
    rt_msghdr message;
    std::memcpy(&message, bytes.data(), sizeof(message));
    if (message.rtm_msglen != bytes.size() || message.rtm_version != RTM_VERSION || message.rtm_type != RTM_GET) { throw EncodingError{"Invalid route reply"}; }
    if (message.rtm_errno != 0) { throw SystemError{"Resolve original route", message.rtm_errno}; }
    if (message.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE)) { throw SystemError{"Original route does not forward traffic", ENETUNREACH}; }
    RoutePath path;
    path.index = message.rtm_index;
    std::size_t offset = sizeof(message);
    for (unsigned index = 0; index < RTAX_MAX; ++index) {
      if (!(message.rtm_addrs & (1U << index))) { continue; }
      if (offset + 2 > bytes.size()) { throw EncodingError{"Truncated route address"}; }
      const auto length = bytes[offset];
      const auto family = bytes[offset + 1];
      const auto size = aligned(length);
      if (size > bytes.size() - offset) { throw EncodingError{"Invalid route address size"}; }
      if (index == RTAX_GATEWAY && (message.rtm_flags & RTF_GATEWAY)) {
        if (family == AF_INET && length >= sizeof(sockaddr_in)) {
          sockaddr_in address;
          std::memcpy(&address, bytes.data() + offset, sizeof(address));
          addressText(path.gateway, AF_INET, &address.sin_addr);
        } else if (family == AF_INET6 && length >= sizeof(sockaddr_in6)) {
          sockaddr_in6 address;
          std::memcpy(&address, bytes.data() + offset, sizeof(address));
          if (IN6_IS_ADDR_LINKLOCAL(&address.sin6_addr)) {
            // Darwin embeds the interface scope in the second 16-bit word.
            std::fill_n(address.sin6_addr.s6_addr + sizeof(std::uint16_t), sizeof(std::uint16_t), Byte{0});
          }
          addressText(path.gateway, AF_INET6, &address.sin6_addr);
        } else { throw EncodingError{"Unsupported original route gateway"}; }
      }
      offset += size;
    }
    std::array<char, IFNAMSIZ> name{};
    if (path.index == 0 || !::if_indextoname(path.index, name.data())) { throw SystemError{"Original route interface is unavailable", ENXIO}; }
    path.interface.assign(name.data());
    if (path.gateway.view().empty()) { path.gateway.assign(target.host.view()); }
    return path;
  }

private:
  static constexpr std::size_t maximum_message_bytes = 4096;
  static constexpr std::size_t address_alignment = sizeof(std::uint32_t);
  inline static std::size_t aligned(std::size_t size) noexcept { return size == 0 ? address_alignment : (size + address_alignment - 1) & ~(address_alignment - 1); }

  inline static void addressText(FixedText<INET6_ADDRSTRLEN> &target, int family, const void *address) {
    std::array<char, INET6_ADDRSTRLEN> text{};
    if (!::inet_ntop(family, address, text.data(), text.size())) { throw SystemError{"Format original route gateway"}; }
    target.assign(text.data());
  }
};

}
}

// Interface: redirect/pf_rules.cppm
export {
namespace telar::runtime::redirect {

struct Mapping {
  Target target;
  std::uint16_t listener_port = 0;
  bool incoming = false;

  // Established inbound packets can hit NAT state on the physical interface;
  // preserve the local IP so their translated destination remains deliverable.
  inline std::string_view listenerAddress() const noexcept {
    return incoming ? target.host.view() : target.endpoint.storage.ss_family == AF_INET6 ? "::1" : "127.0.0.1";
  }
};

struct Bypass {
  FlowKey key;
  RoutePath route;
};

struct PfScope {
  uid_t uid;
  std::string_view label;
  std::string_view discovery_interface;
  std::span<const FlowKey> flows;
  std::optional<unsigned> log_interface{};
  std::span<const Bypass> bypasses{};
  bool log_all = false;
  Direction direction = Direction::outbound;
  std::span<const FlowKey> incoming_flows{};
};

template <Allocator Memory>
class PfIdentity {
public:
  inline explicit PfIdentity(Memory &memory, std::string_view endpoint)
      : anchor(AllocatorRef<char, Memory>{memory}), label(AllocatorRef<char, Memory>{memory}) {
    const auto hash = plugins::stableId(endpoint);
    std::array<char, 32> hex{};
    std::snprintf(hex.data(), hex.size(), "tlr_%016llx", static_cast<unsigned long long>(hash));
    label = hex.data();
    anchor = "com.apple/telar-redirect-";
    anchor += label;
  }

  String<Memory> anchor;
  String<Memory> label;
};

template <Allocator Memory>
String<Memory> pfRules(Memory &memory, std::span<const Mapping> mappings, const PfScope &scope) {
  const auto uid = scope.uid;
  const auto label = scope.label;
  const auto interface = scope.discovery_interface;
  if (uid == 0 || mappings.empty() || mappings.size() > Target::maximum_targets || label.empty() || label.size() > 48 || label.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string_view::npos || !interface.starts_with("utun") || interface.size() <= 4 || interface.size() >= IFNAMSIZ || interface.substr(4).find_first_not_of("0123456789") != std::string_view::npos || scope.flows.size() + scope.incoming_flows.size() + scope.bypasses.size() > 256 || (!allowsIncoming(scope.direction) && !allowsOutgoing(scope.direction)) || (!allowsOutgoing(scope.direction) && (!scope.flows.empty() || !scope.bypasses.empty())) || (!allowsIncoming(scope.direction) && !scope.incoming_flows.empty())) {
    throw std::invalid_argument{"Invalid transparent redirect scope"};
  }
  String<Memory> rules{AllocatorRef<char, Memory>{memory}};
  if ((scope.log_interface && *scope.log_interface >= 16) || (allowsIncoming(scope.direction) && !std::ranges::any_of(mappings, [](const auto &mapping) { return mapping.incoming; }))) { throw std::invalid_argument{"Invalid incoming discovery scope"}; }
  std::array<char, 512> line{};
  for (const auto &mapping : mappings) {
    if (mapping.listener_port == 0 || (mapping.target.host.view() == "127.0.0.1" && mapping.listener_port == mapping.target.port) || (mapping.target.host.view() == "::1" && mapping.listener_port == mapping.target.port)) {
      throw std::invalid_argument{"Redirect listener overlaps its destination"};
    }
  }
  // Discovery has already selected the account. Exact tuples survive loopback
  // metadata changes and cannot match the helper's distinct upstream sockets.
  for (const auto &flow : scope.incoming_flows) {
    if (!std::ranges::any_of(mappings, [&](const auto &mapping) { return mapping.incoming && FlowKey::same(mapping.target, flow.destination); })) { throw std::invalid_argument{"Incoming flow is outside the local destination scope"}; }
  }
  for (const auto &bypass : scope.bypasses) {
    const auto &flow = bypass.key;
    const auto name = bypass.route.interface.view();
    const auto gateway = bypass.route.gateway.view();
    const auto family = flow.destination.endpoint.storage.ss_family;
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::array<Byte, sizeof(in6_addr)> address{};
    if (name.empty() || name.size() >= IFNAMSIZ || name == interface || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string_view::npos || gateway.empty() || gateway.size() >= text.size() || family != flow.source.endpoint.storage.ss_family || !std::ranges::any_of(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); })) { throw std::invalid_argument{"Invalid original route bypass"}; }
    std::ranges::copy(gateway, text.begin());
    if (::inet_pton(family, text.data(), address.data()) != 1) { throw std::invalid_argument{"Bypass gateway must be numeric"}; }
  }
  for (const auto group : {scope.flows, scope.incoming_flows}) {
    for (const auto &flow : group) {
      const auto selected = std::ranges::find_if(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); });
      if (selected == mappings.end() || flow.source.endpoint.storage.ss_family != flow.destination.endpoint.storage.ss_family) {
        throw std::invalid_argument{"Discovered flow is outside the redirect scope"};
      }
      const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
      const auto source = flow.source.host.view();
      const auto destination = flow.destination.host.view();
      const auto listener = selected->listenerAddress();
      const auto count = std::snprintf(line.data(), line.size(), "rdr on lo0 %s proto tcp from %.*s port %u to %.*s port %u -> %.*s port %u\n", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, static_cast<int>(listener.size()), listener.data(), selected->listener_port);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  for (const auto &bypass : scope.bypasses) {
    const auto &flow = bypass.key;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto name = bypass.route.interface.view();
    const auto gateway = bypass.route.gateway.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass out quick route-to (%.*s %.*s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags S/SA no state\n", static_cast<int>(name.size()), name.data(), static_cast<int>(gateway.size()), gateway.data(), flow.destination.endpoint.storage.ss_family == AF_INET6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto group : {scope.flows, scope.incoming_flows}) {
    for (const auto &flow : group) {
      const auto selected = std::ranges::find_if(mappings, [&](const auto &mapping) { return FlowKey::same(mapping.target, flow.destination); });
      const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
      const auto source = flow.source.host.view();
      const auto listener = selected->listenerAddress();
      const auto count = std::snprintf(line.data(), line.size(), "pass in quick on lo0 %s proto tcp from %.*s port %u to %.*s port %u flags S/SA keep state label \"%.*s\"\n", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(listener.size()), listener.data(), selected->listener_port, static_cast<int>(label.size()), label.data());
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  for (const auto &flow : scope.flows) {
    const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass out quick route-to (lo0 %s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags any no state\n", ipv6 ? "::1" : "127.0.0.1", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto &flow : scope.incoming_flows) {
    const bool ipv6 = flow.destination.endpoint.storage.ss_family == AF_INET6;
    const auto source = flow.source.host.view();
    const auto destination = flow.destination.host.view();
    const auto count = std::snprintf(line.data(), line.size(), "pass in quick on ! lo0 route-to (lo0 %s) %s proto tcp from %.*s port %u to %.*s port %u user %u flags any no state\n", ipv6 ? "::1" : "127.0.0.1", ipv6 ? "inet6" : "inet", static_cast<int>(source.size()), source.data(), flow.source.port, static_cast<int>(destination.size()), destination.data(), flow.destination.port, uid);
    rules.append(line.data(), static_cast<std::size_t>(count));
  }
  for (const auto &mapping : mappings) {
    const bool ipv6 = mapping.target.endpoint.storage.ss_family == AF_INET6;
    const auto host = mapping.target.host.view();
    std::array<char, 48> logging{};
    if ((host == "::1" || scope.log_all) && scope.log_interface) {
      if (*scope.log_interface >= 16) { throw std::invalid_argument{"Invalid discovery log interface"}; }
      std::snprintf(logging.data(), logging.size(), " log (user, to pflog%u)", *scope.log_interface);
    }
    if (allowsOutgoing(scope.direction)) {
      const auto count = std::snprintf(line.data(), line.size(), "pass out%s quick on ! %.*s route-to %.*s %s proto tcp from any to %.*s port %u user %u flags S/SA no state\n", logging.data(), static_cast<int>(interface.size()), interface.data(), static_cast<int>(interface.size()), interface.data(), ipv6 ? "inet6" : "inet", static_cast<int>(host.size()), host.data(), mapping.target.port, uid);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
    if (allowsIncoming(scope.direction) && mapping.incoming && scope.log_interface) {
      const auto count = std::snprintf(line.data(), line.size(), "pass in log (user, to pflog%u) quick on ! lo0 route-to %.*s %s proto tcp from any to %.*s port %u user %u flags S/SA no state\n", *scope.log_interface, static_cast<int>(interface.size()), interface.data(), ipv6 ? "inet6" : "inet", static_cast<int>(host.size()), host.data(), mapping.target.port, uid);
      rules.append(line.data(), static_cast<std::size_t>(count));
    }
  }
  return rules;
}

}
}
