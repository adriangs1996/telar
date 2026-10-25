#pragma once

#include "http2/frame.hpp"
#include <string>
#include <string_view>

inline std::string http2Frame(telar::runtime::Http2FrameKind kind, std::uint8_t flags, std::uint32_t stream, std::string_view payload) {
  const auto length = payload.size();
  std::string bytes{
      static_cast<char>(length >> 16),
      static_cast<char>(length >> 8),
      static_cast<char>(length),
      static_cast<char>(kind),
      static_cast<char>(flags),
      static_cast<char>(stream >> 24),
      static_cast<char>(stream >> 16),
      static_cast<char>(stream >> 8),
      static_cast<char>(stream),
  };
  bytes.append(payload);
  return bytes;
}
