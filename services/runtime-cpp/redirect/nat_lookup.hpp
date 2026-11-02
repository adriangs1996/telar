#pragma once

#include "flow_key.hpp"
#include "../platform/file_descriptor.hpp"
#include "../platform/error.hpp"
#include <fcntl.h>
#include <sys/ioctl.h>

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
  NatLookup() : device_(::open("/dev/pf", O_RDWR | O_CLOEXEC | O_NOFOLLOW)) {
    if (!device_) { throw SystemError{"Open redirect NAT lookup"}; }
  }

  bool matches(int socket, const FlowKey &flow) const {
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

  static bool peerMatches(int socket, const FlowKey &flow) {
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
  static void address(const sockaddr_storage &socket, std::span<Byte, 16> bytes, std::uint32_t &port) {
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
