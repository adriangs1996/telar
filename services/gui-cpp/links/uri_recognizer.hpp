#pragma once

#include "link_text.hpp"
#include "text/ascii.hpp"
#include "uri_view.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

class UriRecognizer {
public:
  [[nodiscard]] static std::optional<LinkScheme> classify(std::string_view text) {
    if (text.empty() || text.size() > LinkText::maximum_uri_bytes || std::ranges::any_of(text, LinkText::separator) || !LinkText::validUtf8(text)) {
      return {};
    }

    const auto uri = UriView::parse(text);
    if (!uri) {
      return {};
    }

    for (const auto &prefix : prefixes) {
      const auto name = prefix.text.substr(0, prefix.text.find(':'));
      if (!runtime::asciiEqualIgnoreCase(uri->scheme, name)) {
        continue;
      }

      switch (prefix.scheme) {
      case LinkScheme::http:
      case LinkScheme::https:
        return uri->host ? std::optional{prefix.scheme} : std::nullopt;
      case LinkScheme::file:
        return uri->path.starts_with('/') ? std::optional{prefix.scheme} : std::nullopt;
      case LinkScheme::external:
        if (text.size() <= uri->scheme.size() + 1 || (text.substr(uri->scheme.size() + 1).starts_with("//") && !uri->host)) {
          return {};
        }

        return prefix.scheme;
      case LinkScheme::path:
        return {};
      }
    }

    return {};
  }

  [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size()) {
      return {};
    }

    const auto lower = byte_offset - std::min(byte_offset, LinkText::maximum_uri_bytes - 1);
    auto index = byte_offset + 1;
    while (index > lower) {
      --index;
      const auto prefix = prefixAt(line.substr(index));
      if (!prefix || !validStart(line, index)) {
        continue;
      }

      const auto limit = index + std::min(line.size() - index, LinkText::maximum_uri_bytes + 1);
      auto end = index;
      while (end < limit && !LinkText::separator(line[end])) {
        ++end;
      }

      if (end < line.size() && !LinkText::separator(line[end])) {
        continue;
      }

      end = index + trimEnd(line.substr(index, end - index));
      if (byte_offset >= end || classify(line.substr(index, end - index)) != prefix->scheme) {
        continue;
      }

      return LinkTextMatch{.scheme = prefix->scheme, .extent = {.start = index, .end = end}, .destination = {.start = index, .end = end}};
    }

    return {};
  }

private:
  struct Prefix {
    std::string_view text;
    LinkScheme scheme;
  };

  static constexpr auto prefixes = std::to_array<Prefix>({
      {.text = "https://", .scheme = LinkScheme::https},
      {.text = "http://", .scheme = LinkScheme::http},
      {.text = "file://", .scheme = LinkScheme::file},
      {.text = "mailto:", .scheme = LinkScheme::external},
      {.text = "ftp://", .scheme = LinkScheme::external},
      {.text = "ssh:", .scheme = LinkScheme::external},
      {.text = "git://", .scheme = LinkScheme::external},
      {.text = "tel:", .scheme = LinkScheme::external},
      {.text = "magnet:", .scheme = LinkScheme::external},
      {.text = "ipfs://", .scheme = LinkScheme::external},
      {.text = "ipns://", .scheme = LinkScheme::external},
      {.text = "gemini://", .scheme = LinkScheme::external},
      {.text = "gopher://", .scheme = LinkScheme::external},
      {.text = "news:", .scheme = LinkScheme::external},
  });

  [[nodiscard]] static std::optional<Prefix> prefixAt(std::string_view text) {
    for (const auto &prefix : prefixes) {
      if (text.size() >= prefix.text.size() && runtime::asciiEqualIgnoreCase(text.substr(0, prefix.text.size()), prefix.text)) {
        return prefix;
      }
    }

    return {};
  }

  [[nodiscard]] static bool validStart(std::string_view line, std::size_t index) noexcept {
    return index == 0 || (!LinkText::alphanumeric(line[index - 1]) && line[index - 1] != '_');
  }

  [[nodiscard]] static std::size_t trimEnd(std::string_view text) noexcept {
    constexpr std::string_view openers{"([{"};
    constexpr std::string_view closers{")]}"};
    constexpr std::size_t pair_count = 3;
    std::array<std::ptrdiff_t, pair_count> balance{};
    for (const auto byte : text) {
      if (const auto index = openers.find(byte); index < balance.size()) {
        --balance[index];
      } else if (const auto index = closers.find(byte); index != std::string_view::npos) {
        ++balance[index];
      }
    }

    auto end = text.size();
    while (end != 0) {
      const auto byte = text[end - 1];
      if (std::string_view{".,;:!?"}.contains(byte)) {
        --end;

        continue;
      }

      const auto pair = closers.find(byte);
      if (pair == std::string_view::npos || balance[pair] <= 0) {
        break;
      }

      --balance[pair];
      --end;
    }

    return end;
  }
};

}
