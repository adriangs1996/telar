module;

#include <cstddef>
#include <cstdint>


#include <cstring>

export module telar.runtime.http2.frame_reader;

import std;


// Interface: http2/frame.cppm
export {
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

  inline bool has(Http2Flag flag) const noexcept {
    return (flags & static_cast<std::uint8_t>(flag)) != 0;
  }

  inline bool containsHeaders() const noexcept {
    return kind == Http2FrameKind::headers || kind == Http2FrameKind::push_promise || kind == Http2FrameKind::continuation;
  }
};

}
}

// Interface: http2/frame_reader.cppm
export {
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
  inline void feed(std::span<const std::uint8_t> input, Receiver receive) noexcept {
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

  inline bool incomplete() const noexcept {
    return header_length_ != 0;
  }

private:
  inline void decodeHeader() noexcept {
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
}

// Interface: http2/stream_ids.cppm
export {
namespace telar::runtime {

template <std::size_t Capacity>
class Http2StreamIds {
public:
  inline bool start(std::uint32_t stream) noexcept {
    if (stream == 0 || std::ranges::find(ids_, stream) != ids_.end()) {
      return false;
    }

    const auto available = std::ranges::find(ids_, 0);
    if (available == ids_.end()) {
      return false;
    }
    *available = stream;
    ++count_;
    return true;
  }

  inline bool finish(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return false;
    }

    const auto existing = std::ranges::find(ids_, stream);
    if (existing == ids_.end()) {
      return false;
    }
    *existing = 0;
    --count_;
    return true;
  }

  inline bool full() const noexcept { return count_ == Capacity; }
  inline std::uint32_t size() const noexcept { return count_; }

private:
  std::array<std::uint32_t, Capacity> ids_{};
  std::uint32_t count_ = 0;
};

}
}

// Interface: http2/stream_tracker.cppm
export {
namespace telar::runtime {

class Http2StreamTracker {
public:
  static constexpr std::size_t capacity = 128;

  struct Response {
    std::uint32_t stream = 0;
    std::uint16_t status = 0;
    bool event_stream = false;
  };

  inline bool startRequest(std::uint32_t stream) noexcept { return requests_.start(stream); }
  inline void finishRequest(std::uint32_t stream) noexcept { requests_.finish(stream); }
  inline bool requestsFull() const noexcept { return requests_.full(); }

  inline bool setResponse(Response response) noexcept {
    if (response.stream == 0) {
      return false;
    }

    Response *available = nullptr;
    for (auto &entry : responses_) {
      if (entry.stream == response.stream) {
        entry = response;
        return true;
      }
      if (entry.stream == 0 && available == nullptr) {
        available = &entry;
      }
    }

    if (available == nullptr) {
      return false;
    }
    *available = response;
    ++response_count_;
    return true;
  }

  inline Response response(std::uint32_t stream) const noexcept {
    for (const auto &entry : responses_) {
      if (entry.stream == stream) {
        return entry;
      }
    }
    return {};
  }

  inline void finishResponse(std::uint32_t stream) noexcept {
    if (stream == 0) {
      return;
    }
    for (auto &entry : responses_) {
      if (entry.stream == stream) {
        entry = {};
        --response_count_;
        return;
      }
    }
  }

  inline bool hasResponses() const noexcept { return response_count_ != 0; }

private:
  Http2StreamIds<capacity> requests_;
  std::array<Response, capacity> responses_{};
  std::size_t response_count_ = 0;
};

}
}
