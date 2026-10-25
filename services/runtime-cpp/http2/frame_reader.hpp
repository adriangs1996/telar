#pragma once

#include "frame.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstring>
#include <span>

namespace telar::runtime {

struct Http2FrameEvent {
  enum class Kind {
    begin,
    payload,
    end
  };

  Kind kind;
  const Http2Frame &frame;
  std::size_t offset = 0;
  std::span<const std::uint8_t> bytes{};
};

class Http2FrameReader {
public:
  template <typename Receiver>
    requires requires(Receiver receive, const Http2FrameEvent &event) {
      { receive(event) } noexcept -> std::same_as<void>;
    }
  void feed(std::span<const std::uint8_t> input, Receiver receive) noexcept {
    while (!input.empty()) {
      if (header_length_ != header_.size()) {
        const auto count = std::min(header_.size() - header_length_, input.size());
        std::memcpy(header_.data() + header_length_, input.data(), count);
        header_length_ += count;
        input = input.subspan(count);
        if (header_length_ != header_.size()) {
          continue;
        }
        decodeHeader();
        receive(Http2FrameEvent{Http2FrameEvent::Kind::begin, frame_});
      } else {
        const auto count = std::min(frame_.length - payload_offset_, input.size());
        receive(Http2FrameEvent{Http2FrameEvent::Kind::payload, frame_, payload_offset_, input.first(count)});
        payload_offset_ += count;
        input = input.subspan(count);
      }
      if (payload_offset_ == frame_.length) {
        receive(Http2FrameEvent{Http2FrameEvent::Kind::end, frame_});
        header_length_ = 0;
        payload_offset_ = 0;
      }
    }
  }

  bool incomplete() const noexcept {
    return header_length_ != 0;
  }

private:
  void decodeHeader() noexcept {
    frame_.length = (std::size_t{header_[0]} << 16) | (std::size_t{header_[1]} << 8) | header_[2];
    frame_.kind = static_cast<Http2FrameKind>(header_[3]);
    frame_.flags = header_[4];
    frame_.stream = (static_cast<std::uint32_t>(header_[5] & stream_high_mask) << 24) | (std::uint32_t{header_[6]} << 16) | (std::uint32_t{header_[7]} << 8) | header_[8];
    payload_offset_ = 0;
  }

  static constexpr std::uint8_t stream_high_mask = 0x7f;
  std::array<std::uint8_t, Http2Frame::header_bytes> header_;
  Http2Frame frame_;
  std::size_t header_length_ = 0;
  std::size_t payload_offset_ = 0;
};

}
