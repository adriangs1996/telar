module telar.runtime.platform.name_resolutions;

import telar.sys.socket;

namespace telar::runtime {

  ResolutionSummary SystemNameResolver::resolve(const char* hostname, std::span<NetworkAddress> addresses) noexcept {
    addrinfo hints{};

    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* entries = nullptr;
    int error;

    do {
      error = ::getaddrinfo(hostname, nullptr, &hints, &entries);
    } while (error == EAI_SYSTEM && sys::lastError() == EINTR);

    if (error != 0) {
      return {.error = error};
    }

    std::size_t found = 0;

    for (const auto* entry = entries; entry != nullptr; entry = entry->ai_next) {
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

}
