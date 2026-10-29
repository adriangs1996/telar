#pragma once

#include "link_text.hpp"
#include "memory/fixed_text.hpp"
#include "uri_recognizer.hpp"
#include <algorithm>
#include <optional>
#include <string_view>

namespace telar::gui {

class LinkTarget {
public:
  [[nodiscard]] static std::optional<LinkTarget> fromUri(std::string_view text) {
    const auto scheme = UriRecognizer::classify(text);

    return scheme ? std::optional{LinkTarget{*scheme, text}} : std::nullopt;
  }

  [[nodiscard]] static std::optional<LinkTarget> fromPath(std::string_view text) {
    if (text.empty() || text.size() > LinkText::maximum_uri_bytes || !LinkText::validUtf8(text) || std::ranges::any_of(text, LinkText::control)) {
      return {};
    }

    return LinkTarget{LinkScheme::path, text};
  }

  [[nodiscard]] LinkScheme scheme() const noexcept {
    return scheme_;
  }

  [[nodiscard]] std::string_view text() const noexcept {
    return text_.view();
  }

  bool operator==(const LinkTarget &other) const noexcept {
    return scheme_ == other.scheme_ && text() == other.text();
  }

private:
  LinkTarget(LinkScheme scheme, std::string_view text)
      : scheme_(scheme) {
    text_.assign(text);
  }

  LinkScheme scheme_;
  runtime::FixedText<LinkText::maximum_uri_bytes> text_;
};

}
