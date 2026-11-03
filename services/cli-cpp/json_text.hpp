#pragma once

#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::runtime::cli {

// The two ways the Zig CLI escaped JSON strings; `--json` output keeps each
// command's own. `standard` is std.json.Stringify: \b \f \n \r \t shorthands and
// \u00XX for other control bytes. `control` is control.writeJsonString: only
// \n \r \t shorthands, and DEL escaped too.
enum class JsonEscapes : std::uint8_t {
  standard,
  control
};

inline std::optional<char> jsonShorthand(unsigned char byte, JsonEscapes escapes) noexcept {
  switch (byte) {
  case '\n':
    return 'n';
  case '\r':
    return 'r';
  case '\t':
    return 't';
  case '\b':
    return escapes == JsonEscapes::standard ? std::optional<char>{'b'} : std::nullopt;
  case '\f':
    return escapes == JsonEscapes::standard ? std::optional<char>{'f'} : std::nullopt;
  default:
    return std::nullopt;
  }
}

// Appends `text` as one JSON string literal, quotes included.
template <Allocator Memory>
void appendJsonText(String<Memory> &output, std::string_view text, JsonEscapes escapes) {
  constexpr std::string_view hex = "0123456789abcdef";
  constexpr unsigned char first_printable = 0x20;
  constexpr unsigned char delete_byte = 0x7f;
  output.push_back('"');
  for (const unsigned char byte : text) {
    if (byte == '"' || byte == '\\') {
      output.push_back('\\');
      output.push_back(static_cast<char>(byte));
    } else if (const auto shorthand = jsonShorthand(byte, escapes)) {
      output.push_back('\\');
      output.push_back(*shorthand);
    } else if (byte < first_printable || (byte == delete_byte && escapes == JsonEscapes::control)) {
      output += "\\u00";
      output.push_back(hex[byte >> 4]);
      output.push_back(hex[byte & 15]);
    } else {
      output.push_back(static_cast<char>(byte));
    }
  }

  output.push_back('"');
}

}
