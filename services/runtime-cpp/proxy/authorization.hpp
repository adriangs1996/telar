#pragma once

#include "../memory/sensitive_buffer.hpp"
#include "../text/base64.hpp"
#include "secret.hpp"

namespace telar::runtime {

class ProxyAuthorization {
public:
  static std::optional<ProxySecret> parse(std::string_view head) noexcept {
    std::optional<ProxySecret> secret;
    while (const auto value = next(head)) {
      if (secret) {
        return std::nullopt;
      }

      const auto authorization = trim(*value);
      if (authorization.size() < 7 || !sameCaseInsensitive(authorization.substr(0, 5), "basic") || authorization[5] != ' ') {
        return std::nullopt;
      }

      SensitiveBuffer<decoded_capacity> decoded;
      const auto length = base64::decode(trim(authorization.substr(6)), decoded.bytes());
      if (!length || *length != userinfo_prefix.size() + ProxySecret::hexadecimal_bytes) {
        return std::nullopt;
      }
      const std::string_view userinfo{reinterpret_cast<const char *>(decoded.bytes().data()), *length};
      if (!userinfo.starts_with(userinfo_prefix)) {
        return std::nullopt;
      }

      secret = ProxySecret::fromHexadecimal(userinfo.substr(userinfo_prefix.size()));
      if (!secret) {
        return std::nullopt;
      }
    }
    return secret;
  }

  static bool present(std::string_view head) noexcept {
    return next(head).has_value();
  }

private:
  static bool sameCaseInsensitive(std::string_view left, std::string_view right) noexcept {
    return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char first, char second) { return asciiLower(first) == asciiLower(second); });
  }

  static std::string_view trim(std::string_view value) noexcept {
    const auto first = value.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }
    return value.substr(first, value.find_last_not_of(" \t") - first + 1);
  }

  static std::optional<std::string_view> next(std::string_view &head) noexcept {
    auto line_end = head.find("\r\n");
    if (line_end == std::string_view::npos) {
      head = {};
      return std::nullopt;
    }
    head.remove_prefix(line_end + 2);
    while (!head.empty()) {
      line_end = head.find("\r\n");
      const auto line = head.substr(0, line_end);
      const auto colon = line.find(':');
      if (colon != std::string_view::npos && sameCaseInsensitive(line.substr(0, colon), "proxy-authorization")) {
        return line.substr(colon + 1);
      }
      head.remove_prefix(line_end == std::string_view::npos ? head.size() : line_end + 2);
    }
    return std::nullopt;
  }

  static constexpr std::string_view userinfo_prefix = "telar:";
  static constexpr std::size_t decoded_capacity = 192;
};

}
