module;
#include "tbc/annotations.hpp"

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
      continuation = 9,
    };

    enum class Http2Flag : std::uint8_t {
      end_stream = 1,
      end_headers = 4,
      padded = 8,
      priority = 32,
    };

    struct Http2Frame {
      static constexpr std::size_t header_bytes = 9;
      static constexpr std::size_t settings_entry_bytes = sizeof(std::uint16_t) + sizeof(std::uint32_t);
      std::size_t length = 0;
      std::uint32_t stream = 0;
      Http2FrameKind kind = Http2FrameKind::data;
      std::uint8_t flags = 0;

      bool has(Http2Flag flag) const noexcept;

      bool containsHeaders() const noexcept;
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
        end,
      };

      Kind kind;
      const Http2Frame& frame;
      std::size_t offset = 0;
      std::span<const std::uint8_t> bytes{};
    };

    class Http2FrameReader {
    public:
      // Generic over the caller's receiver, and called for every chunk the relay reads.
      template <typename Receiver>
        requires requires(Receiver receive, const Http2FrameEvent& event) {
          { receive(event) } noexcept -> std::same_as<void>;
        }
      TBC_HOT_PATH void feed(std::span<const std::uint8_t> input, Receiver receive) noexcept {
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

      bool incomplete() const noexcept;

    private:
      void decodeHeader() noexcept;

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
      bool start(std::uint32_t stream) noexcept;

      bool finish(std::uint32_t stream) noexcept;

      bool full() const noexcept;

      std::uint32_t size() const noexcept;

    private:
      std::array<std::uint32_t, Capacity> ids_{};
      std::uint32_t count_ = 0;
    };

    extern template class Http2StreamIds<256>;

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

      bool startRequest(std::uint32_t stream) noexcept;

      void finishRequest(std::uint32_t stream) noexcept;

      bool requestsFull() const noexcept;

      bool setResponse(Response response) noexcept;

      Response response(std::uint32_t stream) const noexcept;

      void finishResponse(std::uint32_t stream) noexcept;

      bool hasResponses() const noexcept;

    private:
      Http2StreamIds<capacity> requests_;
      std::array<Response, capacity> responses_{};
      std::size_t response_count_ = 0;
    };

  }
}
