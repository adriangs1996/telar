#pragma once

#include "../../text/base64.hpp"
#include "graphics_base64_block.hpp"

namespace telar::runtime::control {

// Graphics uses the standard alphabet with optional padding and ASCII
// whitespace. Clipboard decoding remains strict and uses base64::decode.
inline std::optional<std::size_t> decodeGraphicsPayload(std::string_view encoded, std::span<std::uint8_t> output) noexcept {
  std::array<unsigned, 4> group;
  unsigned count = 0;
  unsigned padding = 0;
  std::size_t written = 0;
  const auto emit = [&](unsigned length) {
    if (length > output.size() - written) {
      return false;
    }
    output[written++] = static_cast<std::uint8_t>((group[0] << 2) | (group[1] >> 4));
    if (length >= 2) {
      output[written++] = static_cast<std::uint8_t>((group[1] << 4) | (group[2] >> 2));
    }
    if (length == 3) {
      output[written++] = static_cast<std::uint8_t>((group[2] << 6) | group[3]);
    }
    return true;
  };
  std::size_t offset = 0;
  while (encoded.size() - offset >= graphics_base64_block_input && output.size() - written >= graphics_base64_block_output && decodeGraphicsBlock(encoded.data() + offset, output.data() + written)) {
    offset += graphics_base64_block_input;
    written += graphics_base64_block_output;
  }
  for (std::size_t index = offset; index < encoded.size(); ++index) {
    const auto byte = encoded[index];
    if (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\f') {
      continue;
    }
    if (byte == '=') {
      if (count < 2 || padding == 2 || count + padding >= 4) {
        return std::nullopt;
      }
      ++padding;
      continue;
    }
    if (padding != 0) {
      return std::nullopt;
    }
    const auto digit = base64::alphabet.find(byte);
    if (digit == std::string_view::npos) {
      return std::nullopt;
    }
    group[count++] = static_cast<unsigned>(digit);
    if (count == group.size()) {
      if (!emit(3)) {
        return std::nullopt;
      }
      count = 0;
    }
  }
  if (count == 1 || (padding != 0 && count + padding != 4)) {
    return std::nullopt;
  }
  if (count != 0 && !emit(count - 1)) {
    return std::nullopt;
  }
  return written;
}

}
