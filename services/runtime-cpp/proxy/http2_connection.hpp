#pragma once

#include "../http2/direction_observer.hpp"
#include "counters.hpp"
#include "http2_capture_policy.hpp"
#include "relay_direction.hpp"
#include "socket_interest.hpp"
#include "telar_platform/trace.hpp"

namespace telar::runtime {

template <Allocator Memory, Http2CapturePolicy Capture = IgnoreHttp2Capture>
class Http2Connection {
public:
  explicit Http2Connection(Memory &memory, ProxyCounters &counters, Capture capture = {}) noexcept
      : counters_(counters), capture_(std::move(capture)), request_(memory, Http2Direction::request), response_(memory, Http2Direction::response) {}

  ~Http2Connection() { settle(); }

  template <ByteStream Child, ByteStream Origin>
  bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.http2Exchange");
    if (finished()) {
      return false;
    }

    const bool outgoing = transfer(request_, child, origin, readiness);
    const bool incoming = transfer(response_, origin, child, {readiness.origin, readiness.child});
    if (finished()) {
      origin.halfClose();
      settle();
    }
    return outgoing || incoming;
  }

  bool finished() const noexcept { return response_.relay.finished(); }
  bool halfClosed() const noexcept { return request_.relay.finished() || response_.relay.finished(); }
  bool readsChild() const noexcept { return !finished() && request_.relay.wantsRead(); }
  bool readsOrigin() const noexcept { return response_.relay.wantsRead(); }
  std::uint32_t inflight() const noexcept { return streams_.size(); }

  SocketInterest childInterest() const noexcept {
    SocketInterest interest;
    interest.include(request_.relay.sourceInterest());
    interest.include(response_.relay.destinationInterest());
    return interest;
  }

  SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    interest.include(response_.relay.sourceInterest());
    interest.include(request_.relay.destinationInterest());
    return interest;
  }

private:
  void observe(Http2Direction direction, const Http2Event &event) noexcept {
    if (event.kind == Http2Event::Kind::request_started) {
      streams_.start(event.stream);
    } else if (event.kind == Http2Event::Kind::response_ended || event.kind == Http2Event::Kind::stream_reset) {
      streams_.finish(event.stream);
    }
    capture_.observe(direction, event);
  }

  struct DirectionSink {
    Http2Connection &connection;
    Http2Direction direction;

    void emit(const Http2Event &event) noexcept { connection.observe(direction, event); }
  };

  struct Direction {
    explicit Direction(Memory &memory, Http2Direction value) noexcept : observer(memory, value), kind(value) {}

    Http2DirectionObserver<Memory> observer;
    Http2Direction kind;
    RelayDirection<> relay;
  };

  template <ByteStream Source, ByteStream Destination>
  bool transfer(Direction &direction, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    if (!readiness.child.satisfies(direction.relay.sourceInterest()) && !readiness.origin.satisfies(direction.relay.destinationInterest())) {
      return false;
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds; ++round) {
      const auto progress = direction.relay.advance(source, destination, [&](RelayDirection<>::Observation stage, std::span<const std::uint8_t> bytes) noexcept {
        const bool request = direction.kind == Http2Direction::request;
        if ((request && stage == RelayDirection<>::Observation::received) || (!request && stage == RelayDirection<>::Observation::forwarded)) {
          DirectionSink sink{*this, direction.kind};
          direction.observer.observe(bytes, sink);
        }
      });
      active = active || progress.active();
      if (direction.relay.wantsWrite() || progress.read < RelayDirection<>::capacity) {
        break;
      }
    }
    if (direction.relay.finished()) {
      capture_.finish(direction.kind);
    }
    return active;
  }

  void settle() noexcept {
    if (settled_) {
      return;
    }
    settled_ = true;
    record(request_.observer.finish());
    record(response_.observer.finish());
    capture_.finish(Http2Direction::request);
    capture_.finish(Http2Direction::response);
  }

  void record(const typename Http2Observer<Memory>::Statistics &statistics) noexcept {
    if (statistics.decode_failed) {
      counters_.record(ProxyCounter::h2_decode_failure);
    }
    if (statistics.header_block_too_large) {
      counters_.record(ProxyCounter::h2_header_block_too_large);
    }
    counters_.record(ProxyCounter::h2_stream_untracked, statistics.untracked_streams);
  }

  static constexpr std::size_t maximum_rounds = 8;
  ProxyCounters &counters_;
  [[no_unique_address]] Capture capture_;
  Http2StreamIds<2 * Http2StreamTracker::capacity> streams_;
  Direction request_;
  Direction response_;
  bool settled_ = false;
};

}
