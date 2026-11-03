#pragma once

#include <cstdint>
#include <expected>
#include <string_view>
#include <vector>

namespace telar::clipboard {
  using byte = unsigned char;

  enum class read_error : std::uint8_t {
    no_supported_content,
    encoding_failed,
    changed,
    allocation_failed,
    session_unavailable,
    unsupported_protocol,
    read_failed,
    timed_out,
  };

  struct content {
    std::string_view mime_type;
    std::vector<byte> bytes;
  };

  std::expected<content, read_error> read();
} // namespace telar::clipboard
