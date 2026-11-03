#pragma once

#include "telar_config/proxy/hostname.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <array>

namespace telar::runtime {

class TlsHostname {
public:
  static bool numeric(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) { return false; }
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::ranges::copy(host, text.begin());
    in6_addr address{};
    return ::inet_pton(AF_INET, text.data(), &address) == 1 || ::inet_pton(AF_INET6, text.data(), &address) == 1;
  }

  static bool valid(std::string_view host) noexcept { return ProxyHostname::validTarget(host) || numeric(host); }
};

}
