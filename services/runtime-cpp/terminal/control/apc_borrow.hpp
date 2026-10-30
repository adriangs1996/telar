#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <span>

namespace telar::runtime::control {

// Only a complete unchanged printable APC may borrow input. Other bytes use
// the incremental parser, preserving cancellation and C1 normalization.
[[gnu::noinline]] inline std::size_t completeAsciiApc(std::span<const std::uint8_t> input, std::size_t limit) noexcept {
  if (input.size() < 3 || limit < 3) {
    return 0;
  }
  constexpr std::uint8_t escape = 0x1b;
  constexpr std::uint8_t space = 0x20;
  constexpr std::uint8_t last_ascii = 0x7f;
  const auto body = input.subspan(3, std::min(input.size() - 3, limit - 2));
  const auto *terminator = static_cast<const std::uint8_t *>(std::memchr(body.data(), escape, body.size()));
  if (terminator == nullptr) {
    return 0;
  }
  const auto count = static_cast<std::size_t>(terminator - body.data());
  std::uint8_t maximum_offset = 0;
  for (const auto byte : body.first(count)) {
    maximum_offset = std::max(maximum_offset, static_cast<std::uint8_t>(byte - space));
  }
  return maximum_offset <= last_ascii - space ? count + 3 : 0;
}

}
