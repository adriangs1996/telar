module telar.runtime.http2.direction_observer;

import telar.native.nghttp2;
import telar.runtime.http1.head;
import telar.base.ds;

namespace telar::runtime {

  void Http2HeaderMetadata::observe(std::string_view name, std::string_view value) noexcept {
    if (name == ":status") {
      status_ = parseHttpStatus(value).valueOr(0);
    }

    if (name == ":method") {
      request_ = true;
    }

    if (asciiEqualIgnoreCase(name, "content-type")) {
      if (content_type_seen_) {
        metadata_valid_ = false;
      } else {
        content_type_seen_ = true;
        event_stream_ = isEventStream(value);
      }
    }

    if (asciiEqualIgnoreCase(name, "content-encoding") && !ContentCodings::onlyIdentity(value)) {
      identity_encoding_ = false;
    }
  }

  std::uint16_t Http2HeaderMetadata::status() const noexcept {
    return status_;
  }

  bool Http2HeaderMetadata::request() const noexcept {
    return request_;
  }

  bool Http2HeaderMetadata::eventStream() const noexcept {
    return metadata_valid_ && content_type_seen_ && event_stream_ && identity_encoding_;
  }

  template <Allocator Memory>
  HpackDecoder<Memory>::HpackDecoder(Memory& memory) noexcept
      : memory_(memory) {
    ready_ = nghttp2_hd_inflate_new2(&inflater_, memory_.callbacks()) == 0 && nghttp2_hd_inflate_change_table_size(inflater_, maximum_table_bytes) == 0;
  }

  template <Allocator Memory>
  HpackDecoder<Memory>::~HpackDecoder() {
    if (inflater_ != nullptr) {
      nghttp2_hd_inflate_del(inflater_);
    }
  }

  template <Allocator Memory>
  bool HpackDecoder<Memory>::ready() const noexcept {
    return ready_;
  }

  void Http2PayloadFragment::reset() noexcept {
    padding_ = 0;
  }

  tbc::view<ds::Option<std::span<const std::uint8_t>>, tbc::lt::a> Http2PayloadFragment::body(tbc::view<const Http2FrameEvent&, tbc::lt::a> event) noexcept {
    return extract(event, 0);
  }

  tbc::view<ds::Option<std::span<const std::uint8_t>>, tbc::lt::a> Http2PayloadFragment::headers(tbc::view<const Http2FrameEvent&, tbc::lt::a> event) noexcept {
    std::size_t prefix = 0;

    if (event.frame.kind == Http2FrameKind::headers && event.frame.has(Http2Flag::priority)) {
      prefix = priority_bytes;
    } else if (event.frame.kind == Http2FrameKind::push_promise) {
      prefix = promised_stream_bytes;
    }

    return extract(event, prefix);
  }

  tbc::view<ds::Option<std::span<const std::uint8_t>>, tbc::lt::a> Http2PayloadFragment::extract(tbc::view<const Http2FrameEvent&, tbc::lt::a> event, std::size_t prefix) noexcept {
    if (event.frame.has(Http2Flag::padded)) {
      ++prefix;
      if (event.offset == 0 && !event.bytes.empty()) {
        padding_ = event.bytes.front();
      }
    }

    if (prefix > event.frame.length || padding_ > event.frame.length - prefix) {
      return ds::none;
    }

    const auto start = std::max(event.offset, prefix);
    const auto end = std::min(event.offset + event.bytes.size(), event.frame.length - padding_);
    if (start >= end) {
      return std::span<const std::uint8_t>{};
    }

    return event.bytes.subspan(start - event.offset, end - start);
  }

  template <Allocator Memory>
  Http2Observer<Memory>::Http2Observer(Memory& memory, Http2Direction direction) noexcept
      : decoder_(memory),
        direction_(direction) {
    statistics_.decode_failed = !decoder_.ready();
  }

  template <Allocator Memory>
  void Http2Observer<Memory>::fail() noexcept {
    statistics_.decode_failed = true;
    block_length_ = 0;
    continuation_stream_ = 0;
    block_kind_ = BlockKind::none;
  }

  template <Allocator Memory>
  auto Http2Observer<Memory>::finish() noexcept -> Statistics {
    if (framing_.incomplete() || continuation_stream_ != 0) {
      fail();
    }

    return statistics_;
  }

  template <Allocator Memory>
  auto Http2Observer<Memory>::statistics() const noexcept -> const Statistics& {
    return statistics_;
  }

  template <Allocator Memory>
  void Http2Observer<Memory>::beginFrame(const Http2Frame& frame) noexcept {
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

  template <Allocator Memory>
  void Http2Observer<Memory>::recordUntracked() noexcept {
    if (statistics_.untracked_streams != std::numeric_limits<std::uint32_t>::max()) {
      ++statistics_.untracked_streams;
    }
  }

  template <Allocator Memory>
  Http2DirectionObserver<Memory>::Http2DirectionObserver(Memory& memory, Http2Direction direction) noexcept
      : observer_(memory, direction),
        direction_(direction) {}

  template <Allocator Memory>
  typename Http2Observer<Memory>::Statistics Http2DirectionObserver<Memory>::finish() noexcept {
    if (direction_ == Http2Direction::request && preface_offset_ != client_preface.size()) {
      observer_.fail();
    }

    return observer_.finish();
  }

  template class HpackDecoder<Memory>;
  template class HpackDecoder<ConcurrentMemory>;
  template class Http2Observer<Memory>;
  template class Http2Observer<ConcurrentMemory>;
  template class Http2DirectionObserver<Memory>;
  template class Http2DirectionObserver<ConcurrentMemory>;

}
