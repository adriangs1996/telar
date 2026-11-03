#pragma once

#include "event.hpp"
#include "header_metadata.hpp"
#include "hpack_decoder.hpp"
#include "payload_fragment.hpp"
#include "stream_tracker.hpp"
#include "telar_base/memory/sensitive_buffer.hpp"

namespace telar::runtime {

template <Allocator Memory>
class Http2Observer {
public:
  static constexpr std::size_t maximum_header_bytes = 128 * 1024;

  struct Statistics {
    bool decode_failed = false;
    bool header_block_too_large = false;
    std::uint32_t untracked_streams = 0;
  };

  explicit Http2Observer(Memory &memory, Http2Direction direction) noexcept : decoder_(memory), direction_(direction) {
    statistics_.decode_failed = !decoder_.ready();
  }

  template <Http2EventSink Sink>
  void observe(std::span<const std::uint8_t> bytes, Sink &sink) noexcept {
    framing_.feed(bytes, [&](const Http2FrameEvent &event) noexcept {
      switch (event.kind) {
      case Http2FrameEvent::Kind::begin:
        beginFrame(event.frame);
        break;
      case Http2FrameEvent::Kind::payload:
        payload(event, sink);
        break;
      case Http2FrameEvent::Kind::end:
        finishFrame(event.frame, sink);
        break;
      }
    });
  }

  void fail() noexcept {
    statistics_.decode_failed = true;
    block_length_ = 0;
    continuation_stream_ = 0;
    block_kind_ = BlockKind::none;
  }

  Statistics finish() noexcept {
    if (framing_.incomplete() || continuation_stream_ != 0) {
      fail();
    }
    return statistics_;
  }

  const Statistics &statistics() const noexcept { return statistics_; }

private:
  enum class BlockKind { none,
                         headers,
                         push_promise };

  void beginFrame(const Http2Frame &frame) noexcept {
    fragment_.reset();
    const bool starts_block = frame.kind == Http2FrameKind::headers || frame.kind == Http2FrameKind::push_promise;
    if (starts_block) {
      block_end_stream_ = frame.has(Http2Flag::end_stream);
    }

    if (statistics_.decode_failed) {
      if (frame.kind == Http2FrameKind::headers && continuation_stream_ == 0) {
        block_stream_ = frame.stream;
        block_kind_ = BlockKind::headers;
      }
      return;
    }

    if (starts_block) {
      if (continuation_stream_ != 0 || frame.stream == 0) {
        fail();
        return;
      }
      block_length_ = 0;
      block_stream_ = frame.stream;
      block_kind_ = frame.kind == Http2FrameKind::headers ? BlockKind::headers : BlockKind::push_promise;
    } else if (frame.kind == Http2FrameKind::continuation) {
      if (continuation_stream_ == 0 || continuation_stream_ != frame.stream) {
        fail();
      }
    } else if (continuation_stream_ != 0) {
      fail();
    }
  }

  template <Http2EventSink Sink>
  void payload(const Http2FrameEvent &event, Sink &sink) noexcept {
    if (event.frame.kind == Http2FrameKind::data && !event.bytes.empty()) {
      Http2StreamTracker::Response response;
      if (direction_ == Http2Direction::response) {
        response = streams_.response(event.frame.stream);
        sink.emit({Http2Event::Kind::response_activity, event.frame.stream, response.status});
      }

      const auto body = fragment_.body(event);
      if (body && !body->empty()) {
        sink.emit({
            .kind = direction_ == Http2Direction::request ? Http2Event::Kind::request_body : Http2Event::Kind::response_body,
            .stream = event.frame.stream,
            .status = response.status,
            .event_stream = response.event_stream,
            .bytes = *body,
        });
      }
    }

    if (statistics_.decode_failed || !event.frame.containsHeaders()) {
      return;
    }
    const auto headers = fragment_.headers(event);
    if (!headers) {
      fail();
      return;
    }
    if (headers->size() > maximum_header_bytes - block_length_) {
      statistics_.header_block_too_large = true;
      fail();
      return;
    }
    if (!headers->empty()) {
      std::memcpy(block_.bytes().data() + block_length_, headers->data(), headers->size());
      block_length_ += headers->size();
    }
  }

  template <Http2EventSink Sink>
  void finishFrame(const Http2Frame &frame, Sink &sink) noexcept {
    if (frame.containsHeaders()) {
      if (frame.has(Http2Flag::end_headers)) {
        continuation_stream_ = 0;
        finishHeaders(sink);
      } else if (frame.kind != Http2FrameKind::continuation) {
        continuation_stream_ = frame.stream;
      }
    }

    if (frame.kind == Http2FrameKind::reset_stream && frame.stream != 0) {
      sink.emit({Http2Event::Kind::stream_reset, frame.stream, streams_.response(frame.stream).status});
      streams_.finishResponse(frame.stream);
      if (direction_ == Http2Direction::request) {
        streams_.finishRequest(frame.stream);
      }
    } else if (direction_ == Http2Direction::response && frame.kind == Http2FrameKind::goaway && streams_.hasResponses()) {
      sink.emit({Http2Event::Kind::connection_lost});
    } else if (frame.kind == Http2FrameKind::data && frame.stream != 0 && frame.has(Http2Flag::end_stream)) {
      finishStream(frame.stream, sink);
    }
  }

  template <Http2EventSink Sink>
  void finishHeaders(Sink &sink) noexcept {
    const auto metadata = statistics_.decode_failed ? Http2HeaderMetadata{} : decodeHeaders(sink);
    if (block_kind_ == BlockKind::headers) {
      if (direction_ == Http2Direction::request) {
        if (metadata.request() && streams_.startRequest(block_stream_)) {
          sink.emit({Http2Event::Kind::request_started, block_stream_});
        } else if (metadata.request() && streams_.requestsFull()) {
          recordUntracked();
        }
      } else if (metadata.status() >= 200 && !streams_.setResponse({block_stream_, metadata.status(), metadata.eventStream()})) {
        recordUntracked();
      }

      if (block_end_stream_) {
        finishStream(block_stream_, sink);
      }
    }

    block_kind_ = BlockKind::none;
    block_end_stream_ = false;
    block_length_ = 0;
  }

  template <Http2EventSink Sink>
  void finishStream(std::uint32_t stream, Sink &sink) noexcept {
    if (direction_ == Http2Direction::request) {
      sink.emit({Http2Event::Kind::request_finished, stream});
      streams_.finishRequest(stream);
    } else {
      sink.emit({Http2Event::Kind::response_ended, stream, streams_.response(stream).status});
      streams_.finishResponse(stream);
    }
  }

  template <Http2EventSink Sink>
  Http2HeaderMetadata decodeHeaders(Sink &sink) noexcept {
    Http2HeaderMetadata metadata;
    const bool decoded = decoder_.decode(block_.bytes().first(block_length_), [&](std::string_view name, std::string_view value) noexcept {
      if (block_kind_ == BlockKind::headers) {
        sink.emit({
            .kind = direction_ == Http2Direction::request ? Http2Event::Kind::request_header : Http2Event::Kind::response_header,
            .stream = block_stream_,
            .name = name,
            .value = value,
        });
      }
      metadata.observe(name, value);
    });

    if (!decoded) {
      fail();
      return {};
    }
    return metadata;
  }

  void recordUntracked() noexcept {
    if (statistics_.untracked_streams != std::numeric_limits<std::uint32_t>::max()) {
      ++statistics_.untracked_streams;
    }
  }

  HpackDecoder<Memory> decoder_;
  Http2Direction direction_;
  Statistics statistics_;
  Http2FrameReader framing_;
  Http2PayloadFragment fragment_;
  Http2StreamTracker streams_;
  SensitiveBuffer<maximum_header_bytes> block_;
  std::size_t block_length_ = 0;
  std::uint32_t continuation_stream_ = 0;
  std::uint32_t block_stream_ = 0;
  BlockKind block_kind_ = BlockKind::none;
  bool block_end_stream_ = false;
};

}
