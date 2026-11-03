#pragma once

#include "../proxy/network_address.hpp"
#include "../proxy/target.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <charconv>

namespace telar::runtime::redirect {

struct Target {
  static constexpr std::size_t maximum_targets = 16;
  FixedText<INET6_ADDRSTRLEN> host;
  NetworkAddress endpoint;
  std::uint16_t port = 0;

  static ProxyTarget authority(std::string_view text) {
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

  static Target parse(std::string_view text) {
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
