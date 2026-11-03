#pragma once

#include "target.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <chrono>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <poll.h>

namespace telar::runtime::redirect {

struct RoutePath {
  FixedText<IFNAMSIZ> interface;
  FixedText<INET6_ADDRSTRLEN> gateway;
  unsigned index = 0;

  static RoutePath lookup(const Target &target, unsigned scope = 0) {
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

  static RoutePath decode(std::span<const Byte> bytes, const Target &target) {
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
  static std::size_t aligned(std::size_t size) noexcept { return size == 0 ? address_alignment : (size + address_alignment - 1) & ~(address_alignment - 1); }

  static void addressText(FixedText<INET6_ADDRSTRLEN> &target, int family, const void *address) {
    std::array<char, INET6_ADDRSTRLEN> text{};
    if (!::inet_ntop(family, address, text.data(), text.size())) { throw SystemError{"Format original route gateway"}; }
    target.assign(text.data());
  }
};

}
