#pragma once

#include <algorithm>
#include <stdexcept>
#include <string>
#include <string_view>

namespace telar::runtime::cli::repository {

inline std::string asciiLower(std::string_view text) {
  std::string result{text};
  for (auto &byte : result) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }

  return result;
}

inline std::string_view trim(std::string_view text, std::string_view characters) {
  const auto first = text.find_first_not_of(characters);
  if (first == text.npos) {
    return {};
  }

  const auto last = text.find_last_not_of(characters);
  return text.substr(first, last - first + 1);
}

inline std::string normalize(std::string_view url) {
  url = trim(url, " \t\r\n");
  std::string_view scheme = "ssh";
  std::string_view authority;
  std::string_view path;
  const auto separator = url.find("://");
  if (separator != url.npos) {
    scheme = url.substr(0, separator);
    const auto rest = url.substr(separator + std::string_view{"://"}.size());
    const auto slash = rest.find('/');
    if (asciiLower(scheme) == "file" || slash == rest.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    authority = rest.substr(0, slash);
    path = rest.substr(slash);
  } else {
    const auto colon = url.find(':');
    if (colon == url.npos || url.substr(0, colon).contains('/')) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    authority = url.substr(0, colon);
    path = url.substr(colon + 1);
  }

  const auto at = authority.rfind('@');
  auto host = authority.substr(at == authority.npos ? 0 : at + 1);
  std::size_t colon;
  if (host.starts_with('[')) {
    const auto close = host.find(']');
    if (close == host.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    colon = close + 1;
    if (colon == host.size()) {
      host = host.substr(1, close - 1);
      colon = host.npos;
    }
  } else {
    colon = host.find(':');
  }

  if (colon != host.npos && colon < host.size()) {
    const auto port = host.substr(colon + 1);
    const auto lower_scheme = asciiLower(scheme);
    if ((lower_scheme == "ssh" && port == "22") || (lower_scheme == "https" && port == "443") || (lower_scheme == "http" && port == "80")) {
      host = host.starts_with('[') ? host.substr(1, colon - 2) : host.substr(0, colon);
    }
  }

  path = trim(path, "/");
  constexpr std::string_view suffix = ".git";
  if (path.ends_with(suffix)) {
    path.remove_suffix(suffix.size());
    while (path.ends_with('/')) {
      path.remove_suffix(1);
    }
  }

  if (host.empty() || path.empty()) {
    throw std::runtime_error{"UnsupportedOrigin"};
  }

  constexpr std::size_t max_identity_bytes = 2048;
  if (host.size() + 1 + path.size() > max_identity_bytes) {
    throw std::runtime_error{"OriginTooLong"};
  }

  return asciiLower(host) + '/' + std::string{path};
}

inline std::string sanitized(std::string_view origin) {
  if (origin.find_first_of("?#\r\n\t ") != origin.npos) {
    throw std::runtime_error{"UnsupportedOrigin"};
  }

  const auto separator = origin.find("://");
  if (separator != origin.npos) {
    const auto start = separator + std::string_view{"://"}.size();
    const auto slash = origin.find('/', start);
    if (slash == origin.npos) {
      throw std::runtime_error{"UnsupportedOrigin"};
    }

    const auto authority = origin.substr(start, slash - start);
    const auto at = authority.rfind('@');
    if (at != authority.npos && !(asciiLower(origin.substr(0, separator)) == "ssh" && !authority.substr(0, at).contains(':'))) {
      return std::string{origin.substr(0, start)} + std::string{origin.substr(start + at + 1)};
    }
  }

  return std::string{origin};
}

}
