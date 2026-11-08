#pragma once

#include "tbc/view.hpp"

#include "reply.hpp"
#include <charconv>
#include <optional>

namespace telar::runtime::control {

inline std::optional<std::uint32_t> glyphCodepoint(std::string_view value) noexcept {
  if (value.starts_with('+')) {
    value.remove_prefix(1);
  }

  if (value.empty() || value.front() == '_' || value.back() == '_') {
    return std::nullopt;
  }

  constexpr std::uint32_t maximum_codepoint = (1u << 21) - 1;
  std::uint32_t result = 0;
  for (const auto byte : value) {
    if (byte == '_') {
      continue;
    }
    const auto digit = byte >= '0' && byte <= '9' ? byte - '0' : byte >= 'a' && byte <= 'f' ? byte - 'a' + 10 : byte >= 'A' && byte <= 'F' ? byte - 'A' + 10 : -1;
    if (digit < 0 || result > (maximum_codepoint - digit) / 16) {
      return std::nullopt;
    }
    result = result * 16 + digit;
  }
  return result;
}

inline tbc::view<std::optional<std::string_view>, tbc::lt::a> glyphOption(tbc::view<std::string_view, tbc::lt::a> options, std::string_view key) noexcept {
  std::optional<std::string_view> result;
  while (!options.empty()) {
    const auto end = options.find(';');
    const auto pair = options.substr(0, end);
    const auto separator = pair.find('=');
    if (separator != std::string_view::npos && pair.substr(0, separator) == key) {
      result = pair.substr(separator + 1);
    }
    if (end == std::string_view::npos) {
      break;
    }
    options.remove_prefix(end + 1);
  }
  return result;
}

// The current C++ clients have no session-glyph renderer. Advertise an empty
// format set and reject registrations, rather than claiming invisible glyphs.
template <Allocator Memory>
void glyph(std::string_view request, Reply<Memory> &reply) {
  if (request.empty() || (request.size() > 1 && request[1] != ';')) {
    return;
  }

  const auto options = request.size() > 1 ? request.substr(2) : std::string_view{};
  switch (request.front()) {
  case 's':
    reply.append("\x1b_25a1;s;fmt=\x1b\\");
    break;
  case 'q': {
    const auto encoded = glyphOption(options, "cp");
    const auto codepoint = encoded ? glyphCodepoint(*encoded) : std::nullopt;
    if (codepoint) {
      reply.append("\x1b_25a1;q;cp=");
      reply.hex(*codepoint, 1);
      reply.append(";status=\x1b\\");
    }
    break;
  }
  case 'r': {
    const auto payload_separator = options.rfind(';');
    if (payload_separator == std::string_view::npos) {
      return;
    }
    const auto metadata = options.substr(0, payload_separator);
    if (glyphOption(metadata, "reply") == "0") {
      return;
    }
    const auto encoded = glyphOption(metadata, "cp");
    const auto codepoint = encoded ? glyphCodepoint(*encoded) : std::nullopt;
    reply.append("\x1b_25a1;r;cp=");
    reply.hex(codepoint.value_or(0), 1);
    reply.append(";status=1;reason=unsupported_format\x1b\\");
    break;
  }
  case 'c':
    reply.append("\x1b_25a1;c;status=0\x1b\\");
    break;
  default:
    break;
  }
}

}
