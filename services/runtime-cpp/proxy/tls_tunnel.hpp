#pragma once

#include "../tls/interception.hpp"
#include "../tls/stream.hpp"
#include "connection_observation.hpp"
#include "duplex_relay.hpp"
#include "http1_capture.hpp"
#include "http1_connection.hpp"
#include "http2_capture.hpp"
#include "http2_connection.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsTunnel {
public:
  explicit TlsTunnel(Memory &memory, const TlsInterception<Memory> &interception, TunnelSockets sockets, std::string_view hostname, ConnectionObservation<Memory> observation)
      : memory_(memory), observation_(observation), hostname_(hostname), session_(interception.open(memory, sockets, hostname)), http1_(nullptr, AllocationDeleter<Http1, Memory>{memory}), http2_(nullptr, AllocationDeleter<Http2, Memory>{memory}) {}

  bool advance(TunnelReadiness readiness) noexcept {
    if (failed_) {
      return false;
    }
    if (!established()) {
      if (session_->advance() == TlsSession<Memory>::State::failed) {
        recordFailure();
        failed_ = true;
        return false;
      }
      if (!established()) {
        return false;
      }
      readiness = TunnelReadiness::available();
    }

    TlsStream child{*session_, TlsSide::child};
    TlsStream origin{*session_, TlsSide::origin};
    readiness.child.readable = readiness.child.readable || session_->buffered(TlsSide::child);
    readiness.origin.readable = readiness.origin.readable || session_->buffered(TlsSide::origin);
    if (session_->protocol() == HttpProtocol::http2) {
      if (!http2_) {
        try {
          Http2Capture capture{observation_.captures, observation_.counters, captureStart(CaptureProtocol::http2)};
          http2_ = makeOwned<Http2>(memory_, memory_, observation_.counters, std::move(capture));
        } catch (...) {
          failed_ = true;
          return false;
        }
      }
      return http2_->advance(child, origin, readiness);
    }
    if (session_->protocol() == HttpProtocol::http11) {
      if (!http1_) {
        try {
          Http1Capture capture{memory_, observation_.captures, captureStart(CaptureProtocol::http1)};
          http1_ = makeOwned<Http1>(memory_, observation_.counters, std::move(capture));
        } catch (...) {
          failed_ = true;
          return false;
        }
      }
      if (!http1_->upgraded()) {
        const bool active = http1_->advance(child, origin, readiness);
        if (!http1_->upgraded()) {
          return active;
        }
        return duplex_.advance(child, origin, TunnelReadiness::available()) || active;
      }
    }
    return duplex_.advance(child, origin, readiness);
  }

  bool established() const noexcept {
    return session_->state() == TlsSession<Memory>::State::established;
  }

  bool finished() const noexcept {
    return failed_ || (http1_ && http1_->finished()) || (http2_ && http2_->finished()) || duplex_.finished();
  }

  bool halfClosed() const noexcept { return http2_ ? http2_->halfClosed() : duplex_.halfClosed(); }
  bool idle() const noexcept { return http1_ && http1_->idle(); }
  std::uint32_t inflight() const noexcept { return http2_ ? http2_->inflight() : http1_ ? http1_->inflight()
                                                                                        : 0; }

  bool buffered() const noexcept {
    if (http2_) {
      return (http2_->readsChild() && session_->buffered(TlsSide::child)) || (http2_->readsOrigin() && session_->buffered(TlsSide::origin));
    }
    const bool child = http1_ && !http1_->upgraded() ? http1_->readsChild() : duplex_.readsChild();
    const bool origin = http1_ && !http1_->upgraded() ? http1_->readsOrigin() : duplex_.readsOrigin();
    return (child && session_->buffered(TlsSide::child)) || (origin && session_->buffered(TlsSide::origin));
  }

  SocketInterest interest(TlsSide side) const noexcept {
    if (!established()) {
      SocketInterest interest;
      interest.include(session_->waiting(side));
      return interest;
    }
    if (http1_ && !http1_->upgraded()) {
      return side == TlsSide::child ? http1_->childInterest() : http1_->originInterest();
    }
    if (http2_) {
      return side == TlsSide::child ? http2_->childInterest() : http2_->originInterest();
    }
    return side == TlsSide::child ? duplex_.childInterest() : duplex_.originInterest();
  }

private:
  using Http1 = Http1Connection<Http1Capture<Memory>>;
  using Http2 = Http2Connection<Memory, Http2Capture<Memory>>;

  CaptureStart captureStart(CaptureProtocol protocol) const noexcept {
    return {.key = {observation_.identity, 0}, .protocol = protocol, .host = hostname_};
  }

  void recordFailure() noexcept {
    using Failure = typename TlsSession<Memory>::Failure;
    switch (session_->failure()) {
    case Failure::context:
      observation_.counters.record(ProxyCounter::tls_context_failure);
      break;
    case Failure::origin_handshake:
      observation_.counters.record(ProxyCounter::tls_upstream_handshake_failure);
      break;
    case Failure::child_handshake:
      observation_.counters.record(ProxyCounter::tls_downstream_handshake_failure);
      break;
    case Failure::mint:
      observation_.counters.record(ProxyCounter::tls_mint_failure);
      break;
    case Failure::none:
      break;
    }
  }

  Memory &memory_;
  ConnectionObservation<Memory> observation_;
  std::string_view hostname_;
  Owned<TlsSession<Memory>, Memory> session_;
  Owned<Http1, Memory> http1_;
  Owned<Http2, Memory> http2_;
  DuplexRelay<> duplex_;
  bool failed_ = false;
};

}
