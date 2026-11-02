#pragma once

#include "link_text.hpp"
#include "uri_recognizer.hpp"
#include <algorithm>
#include <cstddef>
#include <optional>
#include <string_view>

namespace telar::gui {

class MarkdownLinks {
public:
  [[nodiscard]] static std::optional<LinkTextMatch> extract(std::string_view line, std::size_t byte_offset) {
    if (byte_offset >= line.size()) {
      return {};
    }

    const auto lower = byte_offset - std::min(byte_offset, LinkText::maximum_span_bytes);
    auto index = byte_offset + 1;
    while (index > lower) {
      --index;
      if (line[index] != '[') {
        continue;
      }

      if (const auto found = parseAt(line, index)) {
        return byte_offset < found->extent.end ? found : std::nullopt;
      }
    }

    return {};
  }

private:
  [[nodiscard]] static std::optional<LinkTextMatch> parseAt(std::string_view line, std::size_t start) {
    constexpr std::size_t label_delimiters = 2;
    const auto label_limit = start + std::min(line.size() - start, label_delimiters + LinkText::maximum_label_bytes);
    auto label_end = start + 1;
    while (label_end < label_limit && line[label_end] != ']') {
      if (LinkText::control(line[label_end])) {
        return {};
      }

      ++label_end;
    }

    if (label_end >= label_limit || label_end + 1 >= line.size() || line[label_end] != ']' || line[label_end + 1] != '(') {
      return {};
    }

    const auto destination_start = label_end + label_delimiters;
    const auto limit = destination_start + std::min(line.size() - destination_start, LinkText::maximum_uri_bytes + 1);
    std::size_t depth = 0;
    auto end = destination_start;
    while (end < limit) {
      const auto byte = line[end];
      if (byte == '(') {
        ++depth;
      } else if (byte == ')') {
        if (depth == 0) {
          break;
        }

        --depth;
      } else if (LinkText::separator(byte)) {
        return {};
      }

      ++end;
    }

    if (end >= limit) {
      return {};
    }

    const auto scheme = UriRecognizer::classify(line.substr(destination_start, end - destination_start));
    if (!scheme) {
      return {};
    }

    return LinkTextMatch{.scheme = *scheme, .extent = {.start = start, .end = end + 1}, .destination = {.start = destination_start, .end = end}};
  }
};

}
