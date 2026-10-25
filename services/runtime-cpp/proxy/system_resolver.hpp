#pragma once

#include "network_address.hpp"
#include <cerrno>
#include <netdb.h>
#include <span>

namespace telar::runtime {

struct ResolutionSummary {
  std::size_t found = 0;
  int error = 0;
};

class SystemNameResolver {
public:
  static ResolutionSummary resolve(const char *hostname, std::span<NetworkAddress> addresses) noexcept {
    const addrinfo hints{.ai_flags = 0, .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_protocol = IPPROTO_TCP, .ai_addrlen = 0, .ai_canonname = nullptr, .ai_addr = nullptr, .ai_next = nullptr};
    addrinfo *entries = nullptr;
    int error;
    do {
      error = ::getaddrinfo(hostname, nullptr, &hints, &entries);
    } while (error == EAI_SYSTEM && errno == EINTR);
    if (error != 0) {
      return {.error = error};
    }

    std::size_t found = 0;
    for (const auto *entry = entries; entry != nullptr; entry = entry->ai_next) {
      const auto address = NetworkAddress::copy(entry->ai_addr, entry->ai_addrlen);
      if (!address) {
        continue;
      }
      if (found < addresses.size()) {
        addresses[found] = *address;
      }
      ++found;
    }
    ::freeaddrinfo(entries);
    return {.found = found};
  }
};

}
