#pragma once

#include <cstdint>
#include <cstring>
#include <netinet/in.h>
#include <optional>
#include <sys/socket.h>

namespace telar::runtime {

struct NetworkAddress {
  sockaddr_storage storage{};
  socklen_t length = 0;

  static std::optional<NetworkAddress> copy(const sockaddr *source, socklen_t size) noexcept {
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

  void setPort(std::uint16_t port) noexcept {
    if (storage.ss_family == AF_INET) {
      reinterpret_cast<sockaddr_in *>(&storage)->sin_port = htons(port);
    } else if (storage.ss_family == AF_INET6) {
      reinterpret_cast<sockaddr_in6 *>(&storage)->sin6_port = htons(port);
    }
  }

  const sockaddr *address() const noexcept {
    return reinterpret_cast<const sockaddr *>(&storage);
  }
};

}
