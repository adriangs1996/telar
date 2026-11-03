#pragma once

#include "telar_config/proxy/hostname.hpp"
#include <charconv>
#include <cstdint>
#include <optional>

namespace telar::runtime {

struct ProxyTarget {
  std::string_view hostname;
  std::uint16_t port;

  static std::optional<ProxyTarget> parse(std::string_view head) noexcept {
    constexpr std::string_view method = "CONNECT ";
    constexpr std::string_view version = " HTTP/1.1";
    const auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      return std::nullopt;
    }

    const auto line = head.substr(0, line_end);
    if (!line.starts_with(method) || !line.ends_with(version) || line.size() <= method.size() + version.size()) {
      return std::nullopt;
    }

    const auto authority = line.substr(method.size(), line.size() - method.size() - version.size());
    const auto colon = authority.rfind(':');
    if (colon == std::string_view::npos || colon == 0 || colon > ProxyHostname::maximum_bytes) {
      return std::nullopt;
    }

    const auto hostname = authority.substr(0, colon);
    if (!ProxyHostname::validTarget(hostname)) {
      return std::nullopt;
    }

    const auto port_text = authority.substr(colon + 1);
    std::uint16_t port = 0;
    const auto parsed = std::from_chars(port_text.data(), port_text.data() + port_text.size(), port);
    if (parsed.ec != std::errc{} || parsed.ptr != port_text.data() + port_text.size() || port == 0) {
      return std::nullopt;
    }
    return ProxyTarget{hostname, port};
  }
};

}
