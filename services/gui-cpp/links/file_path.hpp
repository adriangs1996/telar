#pragma once

#include "link_target.hpp"
#include "link_text.hpp"
#include "path_recognizer.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/ascii.hpp"
#include "text/bounded_text.hpp"
#include "uri_view.hpp"
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <system_error>

namespace telar::gui {

class FilePath {
public:
  [[nodiscard]] static FilePath parse(const LinkTarget &target) {
    switch (target.scheme()) {
    case LinkScheme::file:
      return fromUri(target.text());
    case LinkScheme::path:
      return fromProse(target.text());
    default:
      throw std::invalid_argument{"NotFileLink"};
    }
  }

  [[nodiscard]] std::string_view text() const noexcept {
    return path_.view();
  }

  [[nodiscard]] std::uint32_t line() const noexcept {
    return line_;
  }

  [[nodiscard]] std::uint32_t column() const noexcept {
    return column_;
  }

private:
  static constexpr std::size_t maximum_host_bytes = 255;
  static constexpr std::size_t escape_bytes = 3;
  static constexpr int hexadecimal_base = 16;

  enum class EscapePolicy : std::uint8_t { strict, tolerant };

  explicit FilePath(PathLocation location)
      : line_(location.line),
        column_(location.line == 0 ? 0 : location.column) {
    path_.assign(location.path);
  }

  [[nodiscard]] static FilePath fromProse(std::string_view text) {
    const auto location = PathRecognizer::locate(text);
    if (location.path.empty() || location.path.starts_with('-')) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    return FilePath{location};
  }

  [[nodiscard]] static std::optional<char> escapedByte(std::string_view text, EscapePolicy policy) noexcept {
    if (text.size() < escape_bytes) {
      return {};
    }

    unsigned byte = 0;
    const auto *const first = text.data() + (policy == EscapePolicy::tolerant && text[1] == '+' ? 2 : 1);
    const auto result = std::from_chars(first, text.data() + escape_bytes, byte, hexadecimal_base);
    if (result.ec == std::errc{} && result.ptr == text.data() + escape_bytes) {
      return static_cast<char>(byte);
    }

    return policy == EscapePolicy::tolerant && text[1] == '-' && text[2] == '0' ? std::optional{char{0}} : std::nullopt;
  }

  template <std::size_t Capacity>
  [[nodiscard]] static BoundedText<Capacity> decode(std::string_view text, EscapePolicy policy = EscapePolicy::strict) {
    BoundedText<Capacity> decoded;
    while (!text.empty()) {
      if (!text.starts_with('%')) {
        decoded.append(text.substr(0, 1));
        text.remove_prefix(1);
        continue;
      }

      const auto character = escapedByte(text, policy);
      if (!character) {
        if (policy == EscapePolicy::strict) {
          throw std::invalid_argument{"InvalidFileLink"};
        }

        decoded.append(text.substr(0, 1));
        text.remove_prefix(1);
        continue;
      }

      decoded.append({&*character, 1});
      text.remove_prefix(escape_bytes);
    }

    return decoded;
  }

  static void validateHost(std::string_view host) {
    if (host.empty() || runtime::asciiEqualIgnoreCase(host, "localhost")) {
      return;
    }

    if (!host.contains('%')) {
      throw std::invalid_argument{"RemoteFileLink"};
    }

    try {
      const auto decoded = decode<maximum_host_bytes>(host, EscapePolicy::tolerant);
      if (runtime::asciiEqualIgnoreCase(decoded.view(), "localhost")) {
        return;
      }
    } catch (const std::length_error &) {
      throw std::length_error{"NoSpaceLeft"};
    }

    throw std::invalid_argument{"RemoteFileLink"};
  }

  [[nodiscard]] static FilePath fromUri(std::string_view text) {
    const auto parsed = UriView::parse(text);
    if (!parsed || parsed->user || parsed->password || parsed->port || parsed->query) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    PathLocation location{.path = {}};
    if (parsed->fragment) {
      const auto fragment = PathRecognizer::fragment(*parsed->fragment);
      if (!fragment) {
        throw std::invalid_argument{"InvalidFileLink"};
      }

      location = *fragment;
    }

    if (parsed->host) {
      validateHost(*parsed->host);
    }

    const auto decoded = decode<LinkText::maximum_uri_bytes>(parsed->path);
    if (!decoded.view().starts_with('/') || decoded.view().contains('\0')) {
      throw std::invalid_argument{"InvalidFileLink"};
    }

    location.path = decoded.view();

    return FilePath{location};
  }

  runtime::FixedText<LinkText::maximum_uri_bytes> path_;
  std::uint32_t line_ = 0;
  std::uint32_t column_ = 0;
};

}
