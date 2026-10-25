#pragma once

#include "../../memory/fixed_text.hpp"
#include "../../text/utf8.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <charconv>

namespace telar::runtime::cli::hooks {

inline std::string_view sessionReference(std::string_view text) noexcept {
  if (text.empty() || text.size() > 64 || text.front() == '-') {
    return {};
  }

  for (const unsigned char byte : text) {
    const bool allowed = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '.' || byte == '_' || byte == '-' || byte == ':';
    if (!allowed) {
      return {};
    }
  }

  return text;
}

inline std::string_view validPrefix(std::string_view text) noexcept {
  while (!text.empty()) {
    try {
      validateUtf8(text);
      return text;
    } catch (const EncodingError &) {
      text.remove_suffix(1);
    }
  }

  return {};
}

inline void eventLine(FixedText<96> &output, std::string_view text) {
  const auto control = std::ranges::find_if(text, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; });
  const auto prefix = utf8Prefix(text.substr(0, static_cast<std::size_t>(control - text.begin())), 96);
  try {
    validateUtf8(prefix);
    output.assign(prefix);
  } catch (const EncodingError &) {
    output.assign({});
  }
}

template <std::size_t Capacity>
void displayText(FixedText<Capacity> &output, std::string_view text, bool multiline) {
  std::array<char, Capacity> bytes;
  std::size_t length = 0;
  for (const unsigned char byte : text) {
    if (length == bytes.size() || (!multiline && byte == '\n')) {
      break;
    }
    if ((byte >= 0x20 && byte != 0x7f) || (multiline && (byte == '\n' || byte == '\t'))) {
      bytes[length++] = static_cast<char>(byte);
    }
  }

  std::string_view result{bytes.data(), length};
  if (multiline) {
    const auto first = result.find_first_not_of(" \n\t");
    result = first == std::string_view::npos ? std::string_view{} : result.substr(first, result.find_last_not_of(" \n\t") - first + 1);
  }

  output.assign(validPrefix(result));
}

inline bool defaultOpenCodeTitle(std::string_view title) noexcept {
  constexpr std::string_view shape = "0000-00-00T00:00:00.000Z";
  for (const auto prefix : {std::string_view{"New session - "}, std::string_view{"Child session - "}}) {
    if (!title.starts_with(prefix) || title.size() != prefix.size() + shape.size()) {
      continue;
    }

    title.remove_prefix(prefix.size());
    for (std::size_t index = 0; index < shape.size(); ++index) {
      if (shape[index] == '0' ? title[index] < '0' || title[index] > '9' : title[index] != shape[index]) {
        return false;
      }
    }

    return true;
  }

  return false;
}

}
