#pragma once

#include <cstddef>
#include <cstdint>

namespace telar::runtime {

enum class Http2FrameKind : std::uint8_t {
  data = 0,
  headers = 1,
  priority = 2,
  reset_stream = 3,
  settings = 4,
  push_promise = 5,
  ping = 6,
  goaway = 7,
  window_update = 8,
  continuation = 9
};

enum class Http2Flag : std::uint8_t {
  end_stream = 1,
  end_headers = 4,
  padded = 8,
  priority = 32
};

struct Http2Frame {
  static constexpr std::size_t header_bytes = 9;
  static constexpr std::size_t settings_entry_bytes = sizeof(std::uint16_t) + sizeof(std::uint32_t);
  std::size_t length = 0;
  std::uint32_t stream = 0;
  Http2FrameKind kind = Http2FrameKind::data;
  std::uint8_t flags = 0;

  bool has(Http2Flag flag) const noexcept {
    return (flags & static_cast<std::uint8_t>(flag)) != 0;
  }

  bool containsHeaders() const noexcept {
    return kind == Http2FrameKind::headers || kind == Http2FrameKind::push_promise || kind == Http2FrameKind::continuation;
  }
};

}
