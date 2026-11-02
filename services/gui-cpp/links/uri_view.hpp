#pragma once

#include "link_text.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::gui {

struct UriView {
  std::string_view scheme;
  std::string_view path;
  std::optional<std::string_view> host = std::nullopt;
  std::optional<std::string_view> user = std::nullopt;
  std::optional<std::string_view> password = std::nullopt;
  std::optional<std::uint16_t> port = std::nullopt;
  std::optional<std::string_view> query = std::nullopt;
  std::optional<std::string_view> fragment = std::nullopt;

  [[nodiscard]] static std::optional<UriView> parse(std::string_view text) {
    const auto colon = text.find(':');
    if (colon == std::string_view::npos || colon == 0) {
      return {};
    }

    UriView result{.scheme = text.substr(0, colon), .path = {}};
    const auto rest = text.substr(colon + 1);
    auto path_start = std::size_t{0};
    if (rest.starts_with("//")) {
      path_start = std::min(rest.find_first_of("/?#", 2), rest.size());
      if (!result.authority(rest.substr(2, path_start - 2), rest.substr(2).starts_with('/'))) {
        return {};
      }
    }

    const auto path_end = std::min(rest.find_first_of("?#", path_start), rest.size());
    result.path = rest.substr(path_start, path_end - path_start);
    auto suffix = rest.substr(path_end);
    if (suffix.starts_with('?')) {
      const auto query_end = std::min(suffix.find('#', 1), suffix.size());
      result.query = suffix.substr(1, query_end - 1);
      suffix.remove_prefix(query_end);
    }

    if (suffix.starts_with('#')) {
      result.fragment = suffix.substr(1);
    }

    return result;
  }

private:
  [[nodiscard]] static std::optional<std::uint16_t> parsePort(std::string_view text) noexcept {
    const auto negative = text.starts_with('-');
    if (text.starts_with('+') || negative) {
      text.remove_prefix(1);
    }

    if (text.empty() || text.front() == '_' || text.back() == '_') {
      return {};
    }

    constexpr unsigned base = 10;
    constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();
    unsigned value = 0;
    for (const auto byte : text) {
      if (byte == '_') {
        continue;
      }

      if (!LinkText::digit(byte)) {
        return {};
      }

      const auto digit = static_cast<unsigned>(byte - '0');
      if (value > (maximum - digit) / base) {
        return {};
      }

      value = (value * base) + digit;
    }

    return negative && value != 0 ? std::nullopt : std::optional{static_cast<std::uint16_t>(value)};
  }

  bool authority(std::string_view text, bool empty_authority_has_path) {
    if (text.empty()) {
      return empty_authority_has_path;
    }

    std::size_t host_start = 0;
    if (const auto user_info_end = text.find('@'); user_info_end != std::string_view::npos) {
      host_start = user_info_end + 1;
      const auto info = text.substr(0, user_info_end);
      const auto separator = info.find(':');
      user = info.substr(0, separator);
      if (separator != std::string_view::npos && separator + 1 < info.size()) {
        password = info.substr(separator + 1);
      }
    }

    if (host_start >= text.size()) {
      return true;
    }

    if (text[host_start] == ']') {
      return false;
    }

    auto host_end = text.size();
    if (text[host_start] == '[') {
      const auto bracket = text.rfind(']');
      if (bracket == std::string_view::npos) {
        return false;
      }

      host_end = bracket + 1;
    }

    const auto colon = text.rfind(':');
    const auto has_port = colon != std::string_view::npos && colon >= (text[host_start] == '[' ? host_end : host_start);
    if (has_port) {
      port = parsePort(text.substr(colon + 1));
      if (!port) {
        return false;
      }

      host_end = std::min(host_end, colon);
    }

    if (host_start >= host_end) {
      return false;
    }

    host = text.substr(host_start, host_end - host_start);

    return true;
  }
};

}
