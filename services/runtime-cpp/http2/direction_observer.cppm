module;
#include "tbc/view.hpp"
#include <cstdlib>
#include <new>

#include <cstdint>


#include <cstring>
#include <cstddef>
#include <nghttp2/nghttp2.h>


export module telar.runtime.http2.direction_observer;

import std;

export import telar.runtime.http1.head;
export import telar.base.text;


export import telar.base.memory;


export import telar.runtime.http2.frame_reader;
import telar.base.diagnostics;

// Interface: http2/event.cppm
export {
namespace telar::runtime {

enum class Http2Direction { request,
                            response };

struct Http2Event {
  enum class Kind {
    request_started,
    response_activity,
    response_ended,
    stream_reset,
    connection_lost,
    request_header,
    response_header,
    request_body,
    response_body,
    request_finished
  };

  Kind kind;
  std::uint32_t stream = 0;
  std::uint16_t status = 0;
  bool event_stream = false;
  std::string_view name{};
  std::string_view value{};
  std::span<const std::uint8_t> bytes{};
};

template <typename Sink>
concept Http2EventSink = requires(Sink &sink, const Http2Event &event) {
  { sink.emit(event) } noexcept -> std::same_as<void>;
};

}
}

// Interface: http2/header_metadata.cppm
export {
namespace telar::runtime {

class Http2HeaderMetadata {
public:
  inline void observe(std::string_view name, std::string_view value) noexcept {
    if (name == ":status") {
      const auto parsed = parseHttpNumber<10>(value);
      status_ = parsed && *parsed <= std::numeric_limits<std::uint16_t>::max() ? static_cast<std::uint16_t>(*parsed) : 0;
    }
    if (name == ":method") {
      request_ = true;
    }
    if (equalIgnoringCase(name, "content-type")) {
      if (content_type_seen_) {
        metadata_valid_ = false;
      } else {
        content_type_seen_ = true;
        event_stream_ = equalIgnoringCase(trimText(value.substr(0, value.find(';')), " \t"), "text/event-stream");
      }
    }
    if (equalIgnoringCase(name, "content-encoding") && !identityEncoding(value)) {
      identity_encoding_ = false;
    }
  }

  inline std::uint16_t status() const noexcept { return status_; }
  inline bool request() const noexcept { return request_; }
  inline bool eventStream() const noexcept { return metadata_valid_ && content_type_seen_ && event_stream_ && identity_encoding_; }

private:
  inline static bool equalIgnoringCase(std::string_view left, std::string_view right) noexcept {
    return std::ranges::equal(left, right, [](char first, char second) { return asciiLower(first) == asciiLower(second); });
  }

  inline static bool identityEncoding(std::string_view value) noexcept {
    TextFields fields{value, ","};
    while (const auto field = fields.next()) {
      if (!equalIgnoringCase(trimText(*field, " \t"), "identity")) {
        return false;
      }
    }
    return true;
  }

  std::uint16_t status_ = 0;
  bool request_ = false;
  bool content_type_seen_ = false;
  bool event_stream_ = false;
  bool identity_encoding_ = true;
  bool metadata_valid_ = true;
};

}
}

// Interface: http2/memory.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class Http2Memory {
  using Blocks = CAllocationBlocks<ErasingAllocator<Memory>>;

public:
  inline explicit Http2Memory(Memory &memory) noexcept : memory_(memory), blocks_(memory_), callbacks_{.mem_user_data = &blocks_, .malloc = &allocate, .free = &release, .calloc = &allocateZeroed, .realloc = &resize} {}
  Http2Memory(const Http2Memory &) = delete;
  Http2Memory &operator=(const Http2Memory &) = delete;
  inline auto callbacks() noexcept -> nghttp2_mem * { return &callbacks_; }

private:
  inline static void *allocate(std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->allocate(size); }
  inline static void release(void *pointer, void *owner) noexcept { static_cast<Blocks *>(owner)->release(pointer); }
  inline static void *allocateZeroed(std::size_t count, std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->allocateZeroed(count, size); }
  inline static void *resize(void *pointer, std::size_t size, void *owner) noexcept { return static_cast<Blocks *>(owner)->resize(pointer, size); }

  ErasingAllocator<Memory> memory_;
  // nghttp2 allocates through the blocks, which allocate from the sibling allocator.
  tbc::view<Blocks, tbc::lt::self> blocks_;
  tbc::view<nghttp2_mem, tbc::lt::self> callbacks_;
};

}
}

// Interface: http2/hpack_decoder.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class HpackDecoder {
public:
  static constexpr std::size_t maximum_table_bytes = 128 * 1024;

  inline explicit HpackDecoder(Memory &memory) noexcept : memory_(memory) {
    ready_ = nghttp2_hd_inflate_new2(&inflater_, memory_.callbacks()) == 0 && nghttp2_hd_inflate_change_table_size(inflater_, maximum_table_bytes) == 0;
  }

  inline ~HpackDecoder() {
    if (inflater_ != nullptr) {
      nghttp2_hd_inflate_del(inflater_);
    }
  }

  HpackDecoder(const HpackDecoder &) = delete;
  HpackDecoder &operator=(const HpackDecoder &) = delete;

  inline bool ready() const noexcept {
    return ready_;
  }

  template <typename Visitor>
    requires requires(Visitor visit, std::string_view name, std::string_view value) {
      { visit(name, value) } noexcept -> std::same_as<void>;
    }
  inline bool decode(std::span<const std::uint8_t> bytes, Visitor visit) noexcept {
    if (!ready_) {
      return false;
    }
    for (;;) {
      nghttp2_nv field;
      int flags = NGHTTP2_HD_INFLATE_NONE;
      const auto consumed = nghttp2_hd_inflate_hd2(inflater_, &field, &flags, bytes.data(), bytes.size(), 1);
      if (consumed < 0 || static_cast<std::size_t>(consumed) > bytes.size()) {
        ready_ = false;
        return false;
      }
      bytes = bytes.subspan(static_cast<std::size_t>(consumed));
      if ((flags & NGHTTP2_HD_INFLATE_EMIT) != 0) {
        visit({reinterpret_cast<const char *>(field.name), field.namelen}, {reinterpret_cast<const char *>(field.value), field.valuelen});
      }
      if ((flags & NGHTTP2_HD_INFLATE_FINAL) != 0) {
        ready_ = nghttp2_hd_inflate_end_headers(inflater_) == 0;
        return ready_;
      }
      if (consumed == 0 && (flags & NGHTTP2_HD_INFLATE_EMIT) == 0) {
        ready_ = false;
        return false;
      }
    }
  }

private:
  // The inflater retains the callback address; memory_ must outlive it.
  Http2Memory<Memory> memory_;
  nghttp2_hd_inflater *inflater_ = nullptr;
  bool ready_ = false;
};

}
}

// Interface: http2/payload_fragment.cppm
export {
namespace telar::runtime {

class Http2PayloadFragment {
public:
  inline void reset() noexcept { padding_ = 0; }

  inline std::optional<std::span<const std::uint8_t>> body(const Http2FrameEvent &event) noexcept {
    return extract(event, 0);
  }

  inline std::optional<std::span<const std::uint8_t>> headers(const Http2FrameEvent &event) noexcept {
    std::size_t prefix = 0;
    if (event.frame.kind == Http2FrameKind::headers && event.frame.has(Http2Flag::priority)) {
      prefix = priority_bytes;
    } else if (event.frame.kind == Http2FrameKind::push_promise) {
      prefix = promised_stream_bytes;
    }
    return extract(event, prefix);
  }

private:
  inline std::optional<std::span<const std::uint8_t>> extract(const Http2FrameEvent &event, std::size_t prefix) noexcept {
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
}

// Interface: http2/observer.cppm
export {
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

  inline explicit Http2Observer(Memory &memory, Http2Direction direction) noexcept : decoder_(memory), direction_(direction) {
    statistics_.decode_failed = !decoder_.ready();
  }

  template <Http2EventSink Sink>
  inline void observe(std::span<const std::uint8_t> bytes, Sink &sink) noexcept {
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

  inline void fail() noexcept {
    statistics_.decode_failed = true;
    block_length_ = 0;
    continuation_stream_ = 0;
    block_kind_ = BlockKind::none;
  }

  inline Statistics finish() noexcept {
    if (framing_.incomplete() || continuation_stream_ != 0) {
      fail();
    }
    return statistics_;
  }

  inline const Statistics &statistics() const noexcept { return statistics_; }

private:
  enum class BlockKind { none,
                         headers,
                         push_promise };

  inline void beginFrame(const Http2Frame &frame) noexcept {
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
  inline void payload(const Http2FrameEvent &event, Sink &sink) noexcept {
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
  inline void finishFrame(const Http2Frame &frame, Sink &sink) noexcept {
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
  inline void finishHeaders(Sink &sink) noexcept {
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
  inline void finishStream(std::uint32_t stream, Sink &sink) noexcept {
    if (direction_ == Http2Direction::request) {
      sink.emit({Http2Event::Kind::request_finished, stream});
      streams_.finishRequest(stream);
    } else {
      sink.emit({Http2Event::Kind::response_ended, stream, streams_.response(stream).status});
      streams_.finishResponse(stream);
    }
  }

  template <Http2EventSink Sink>
  inline Http2HeaderMetadata decodeHeaders(Sink &sink) noexcept {
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

  inline void recordUntracked() noexcept {
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
}

// Interface: http2/direction_observer.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class Http2DirectionObserver {
public:
  static constexpr std::string_view client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

  inline explicit Http2DirectionObserver(Memory &memory, Http2Direction direction) noexcept : observer_(memory, direction), direction_(direction) {}

  template <Http2EventSink Sink>
  inline void observe(std::span<const std::uint8_t> bytes, Sink &sink) noexcept {
    if (direction_ == Http2Direction::request && preface_offset_ < client_preface.size()) {
      const auto count = std::min(client_preface.size() - preface_offset_, bytes.size());
      if (std::memcmp(bytes.data(), client_preface.data() + preface_offset_, count) != 0) {
        observer_.fail();
      }
      preface_offset_ += count;
      bytes = bytes.subspan(count);
    }
    observer_.observe(bytes, sink);
  }

  inline typename Http2Observer<Memory>::Statistics finish() noexcept {
    if (direction_ == Http2Direction::request && preface_offset_ != client_preface.size()) {
      observer_.fail();
    }
    return observer_.finish();
  }

private:
  Http2Observer<Memory> observer_;
  Http2Direction direction_;
  std::size_t preface_offset_ = 0;
};

}
}
