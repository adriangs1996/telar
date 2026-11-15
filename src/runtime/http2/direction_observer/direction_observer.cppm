module;
#include "tbc/annotations.hpp"

export module telar.runtime.http2.direction_observer;

import std;
import telar.native.nghttp2;
import telar.tbc;

import telar.base.memory.allocators;
import telar.base.memory.sensitive;

import telar.runtime.http2.frame_reader;
import telar.runtime.http.content;
import telar.base.diagnostics;
import telar.base.text;
import telar.runtime.http1.head;

// Interface: http2/event.cppm
export {
  namespace telar::runtime {

    enum class Http2Direction {
      request,
      response,
    };

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
        request_finished,
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
    concept Http2EventSink = requires(Sink& sink, const Http2Event& event) {
      { sink.emit(event) } noexcept -> std::same_as<void>;
    };

  }
}

// Interface: http2/header_metadata.cppm
export {
  namespace telar::runtime {

    class Http2HeaderMetadata {
    public:
      void observe(std::string_view name, std::string_view value) noexcept;

      std::uint16_t status() const noexcept;

      bool request() const noexcept;

      bool eventStream() const noexcept;

    private:
      std::uint16_t status_ = 0;
      bool request_ = false;
      bool content_type_seen_ = false;
      bool event_stream_ = false;
      bool identity_encoding_ = true;
      bool metadata_valid_ = true;
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

      explicit HpackDecoder(Memory& memory) noexcept;

      ~HpackDecoder();

      HpackDecoder(const HpackDecoder&) = delete;
      HpackDecoder& operator=(const HpackDecoder&) = delete;

      bool ready() const noexcept;

      // Generic over the caller's visitor, and called for every header block relayed.
      template <typename Visitor>
        requires requires(Visitor visit, std::string_view name, std::string_view value) {
          { visit(name, value) } noexcept -> std::same_as<void>;
        }
      TBC_GENERIC bool decode(std::span<const std::uint8_t> bytes, Visitor visit) noexcept {
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
            visit({reinterpret_cast<const char*>(field.name), field.namelen}, {reinterpret_cast<const char*>(field.value), field.valuelen});
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
      nghttp2_hd_inflater* inflater_ = nullptr;
      bool ready_ = false;
    };

    extern template class HpackDecoder<Memory>;
    extern template class HpackDecoder<ConcurrentMemory>;

  }
}

// Interface: http2/payload_fragment.cppm
export {
  namespace telar::runtime {

    class Http2PayloadFragment {
    public:
      void reset() noexcept;

      tbc::view<std::optional<std::span<const std::uint8_t>>, tbc::lt::a> body(tbc::view<const Http2FrameEvent&, tbc::lt::a> event) noexcept;

      tbc::view<std::optional<std::span<const std::uint8_t>>, tbc::lt::a> headers(tbc::view<const Http2FrameEvent&, tbc::lt::a> event) noexcept;

    private:
      tbc::view<std::optional<std::span<const std::uint8_t>>, tbc::lt::a> extract(tbc::view<const Http2FrameEvent&, tbc::lt::a> event, std::size_t prefix) noexcept;

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

      explicit Http2Observer(Memory& memory, Http2Direction direction) noexcept;

      // Generic over the caller's sink, and called for every chunk relayed.
      template <Http2EventSink Sink>
      TBC_GENERIC void observe(std::span<const std::uint8_t> bytes, Sink& sink) noexcept {
        framing_.feed(bytes, [&](const Http2FrameEvent& event) noexcept {
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

      void fail() noexcept;

      Statistics finish() noexcept;

      const Statistics& statistics() const noexcept;

    private:
      enum class BlockKind {
        none,
        headers,
        push_promise,
      };

      void beginFrame(const Http2Frame& frame) noexcept;

      template <Http2EventSink Sink>
      TBC_GENERIC void payload(const Http2FrameEvent& event, Sink& sink) noexcept {
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
      TBC_GENERIC void finishFrame(const Http2Frame& frame, Sink& sink) noexcept {
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
      TBC_GENERIC void finishHeaders(Sink& sink) noexcept {
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
      TBC_GENERIC void finishStream(std::uint32_t stream, Sink& sink) noexcept {
        if (direction_ == Http2Direction::request) {
          sink.emit({Http2Event::Kind::request_finished, stream});
          streams_.finishRequest(stream);
        } else {
          sink.emit({Http2Event::Kind::response_ended, stream, streams_.response(stream).status});
          streams_.finishResponse(stream);
        }
      }

      template <Http2EventSink Sink>
      TBC_GENERIC Http2HeaderMetadata decodeHeaders(Sink& sink) noexcept {
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

      void recordUntracked() noexcept;

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

    extern template class Http2Observer<Memory>;
    extern template class Http2Observer<ConcurrentMemory>;

  }
}

// Interface: http2/direction_observer.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class Http2DirectionObserver {
    public:
      static constexpr std::string_view client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

      explicit Http2DirectionObserver(Memory& memory, Http2Direction direction) noexcept;

      // Generic over the caller's sink, and called for every chunk relayed.
      template <Http2EventSink Sink>
      TBC_GENERIC void observe(std::span<const std::uint8_t> bytes, Sink& sink) noexcept {
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

      typename Http2Observer<Memory>::Statistics finish() noexcept;

    private:
      Http2Observer<Memory> observer_;
      Http2Direction direction_;
      std::size_t preface_offset_ = 0;
    };

    extern template class Http2DirectionObserver<Memory>;
    extern template class Http2DirectionObserver<ConcurrentMemory>;

  }
}
