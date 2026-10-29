#pragma once

#include "../text/ascii.hpp"
#include <cstddef>
#include <arpa/inet.h>
#include <array>
#include <algorithm>
#include <optional>
#include <string_view>

namespace telar::runtime {

class ProxyHostname {
public:
  static constexpr std::size_t maximum_bytes = 253;

  static bool validPattern(std::string_view pattern) noexcept {
    if (pattern.empty() || pattern.size() > maximum_bytes) {
      return false;
    }
    if (pattern.contains(':')) { return ipv6(pattern).has_value(); }
    if (pattern == "*") {
      return true;
    }
    if (pattern.starts_with("*.")) {
      pattern.remove_prefix(2);
    }
    return validLabels(pattern);
  }

  static bool validTarget(std::string_view hostname) noexcept {
    if (hostname.empty() || hostname.size() > maximum_bytes) {
      return false;
    }
    if (hostname.contains(':')) { return ipv6(hostname).has_value(); }
    if (hostname.ends_with('.')) {
      hostname.remove_suffix(1);
    }
    return validLabels(hostname);
  }

  static std::optional<in6_addr> ipv6(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) { return {}; }
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::ranges::copy(host, text.begin());
    in6_addr address{};
    return ::inet_pton(AF_INET6, text.data(), &address) == 1 ? std::optional{address} : std::nullopt;
  }

private:
  static bool validLabels(std::string_view pattern) noexcept {
    std::size_t label_length = 0;
    char previous = '\0';
    for (const char byte : pattern) {
      if (byte == '.') {
        if (label_length == 0 || label_length > maximum_label_bytes || previous == '-') {
          return false;
        }
        label_length = 0;
      } else if (byte == '-') {
        if (label_length == 0) {
          return false;
        }
        ++label_length;
      } else {
        const char lower = asciiLower(byte);
        if ((lower < 'a' || lower > 'z') && (byte < '0' || byte > '9')) {
          return false;
        }
        ++label_length;
      }
      previous = byte;
    }
    return label_length != 0 && label_length <= maximum_label_bytes && previous != '-';
  }

  static constexpr std::size_t maximum_label_bytes = 63;
};

}
