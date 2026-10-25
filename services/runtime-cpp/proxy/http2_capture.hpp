#pragma once

#include "http2_capture_policy.hpp"
#include "http2_capture_streams.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http2Capture {
public:
  explicit Http2Capture(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context) noexcept
      : request_(producer, counters, context, CaptureSide::request), response_(producer, counters, context, CaptureSide::response) {}

  void observe(Http2Direction direction, const Http2Event &event) noexcept {
    auto &streams = select(direction);
    switch (event.kind) {
    case Http2Event::Kind::request_header:
    case Http2Event::Kind::response_header:
      streams.head(event);
      break;
    case Http2Event::Kind::request_body:
    case Http2Event::Kind::response_body:
      streams.body(event);
      break;
    case Http2Event::Kind::request_finished:
      streams.finish(event.stream, CaptureOutcome::finished);
      break;
    case Http2Event::Kind::response_ended:
      streams.finish(event.stream, event.status >= 400 ? CaptureOutcome::failed : CaptureOutcome::finished);
      break;
    case Http2Event::Kind::stream_reset:
    case Http2Event::Kind::connection_lost:
      streams.finish(event.stream, CaptureOutcome::failed);
      break;
    case Http2Event::Kind::request_started:
    case Http2Event::Kind::response_activity:
      break;
    }
  }

  void finish(Http2Direction direction) noexcept { select(direction).finish(); }

private:
  Http2CaptureStreams<Memory, Clock> &select(Http2Direction direction) noexcept {
    return direction == Http2Direction::request ? request_ : response_;
  }

  Http2CaptureStreams<Memory, Clock> request_;
  Http2CaptureStreams<Memory, Clock> response_;
};

template <ConcurrentAllocator Memory>
Http2Capture(CaptureProducer<Memory> *producer, ProxyCounters &counters, CaptureStart context) -> Http2Capture<Memory>;

}
