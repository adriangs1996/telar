#pragma once

#include <expected>
#include <span>

namespace telar::clipboard {
  using byte = unsigned char;

  enum class read_error : uint8_t {
    no_text,
    encoding_failed,
    buffer_too_small,
  };

  std::expected<std::size_t, read_error> readInto(std::span<byte> buffer);
} // namespace telar::clipboard
