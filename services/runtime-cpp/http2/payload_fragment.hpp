#pragma once

#include "frame_reader.hpp"
#include <optional>

namespace telar::runtime {

class Http2PayloadFragment {
public:
  void reset() noexcept { padding_ = 0; }

  std::optional<std::span<const std::uint8_t>> body(const Http2FrameEvent &event) noexcept {
    return extract(event, 0);
  }

  std::optional<std::span<const std::uint8_t>> headers(const Http2FrameEvent &event) noexcept {
    std::size_t prefix = 0;
    if (event.frame.kind == Http2FrameKind::headers && event.frame.has(Http2Flag::priority)) {
      prefix = priority_bytes;
    } else if (event.frame.kind == Http2FrameKind::push_promise) {
      prefix = promised_stream_bytes;
    }
    return extract(event, prefix);
  }

private:
  std::optional<std::span<const std::uint8_t>> extract(const Http2FrameEvent &event, std::size_t prefix) noexcept {
    if (event.frame.has(Http2Flag::padded)) {
      ++prefix;
      if (event.offset == 0 && !event.bytes.empty()) {
        padding_ = event.bytes.front();
      }
    }

    if (prefix > event.frame.length || padding_ > event.frame.length - prefix) {
      return std::nullopt;
    }
    const auto start = std::max(event.offset, prefix);
    const auto end = std::min(event.offset + event.bytes.size(), event.frame.length - padding_);
    if (start >= end) {
      return std::span<const std::uint8_t>{};
    }
    return event.bytes.subspan(start - event.offset, end - start);
  }

  static constexpr std::size_t priority_bytes = 5;
  static constexpr std::size_t promised_stream_bytes = 4;
  std::size_t padding_ = 0;
};

}
