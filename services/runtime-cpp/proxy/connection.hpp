#pragma once

#include "connection_transport.hpp"
#include "observations.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, HostnameResolver Resolver>
class ProxyConnection {
public:
  using Time = ProxyConnectionPolicy::Time;

  explicit ProxyConnection(Memory &memory, FileDescriptor child, const ProxyOptions<Memory> &options, const ProxySecret &secret, ProxyCounters &counters)
      : counters_(counters), handshake_(std::move(child), options, secret, counters), transport_(memory), policy_(ProxyConnectionPolicy::Clock::now()) {}

  void advance(const TlsInterception<Memory> &interception, ProxyObservations<Memory> &observations, TunnelReadiness readiness, Time now) noexcept {
    if (closed_) {
      return;
    }
    if (!transport_.opened()) {
      handshake_.advance(readiness.origin.writable, now);
      if (!observation_ && !handshake_.hostname().empty()) {
        observation_.emplace(observations.connection());
      }
      if (handshake_.state() == Handshake::State::closed) {
        closed_ = true;
        return;
      }
      if (handshake_.state() != Handshake::State::reading && policy_.phase() == Phase::connect_head) {
        enter(Phase::establishing, now);
      }
      if (handshake_.state() != Handshake::State::established) {
        return;
      }
      try {
        transport_.open(interception, handshake_, *observation_);
        readiness = TunnelReadiness::available();
      } catch (...) {
        if (handshake_.intercept()) {
          counters_.record(ProxyCounter::tls_context_failure);
        }
        closed_ = true;
        return;
      }
    }

    if (transport_.advance(readiness)) {
      policy_.touch(now);
    }
    policy_.exchanges(transport_.inflight());
    if (transport_.finished()) {
      closed_ = true;
    } else if (transport_.halfClosed()) {
      enter(Phase::half_closed, now);
    } else if (transport_.established()) {
      enter(transport_.idle() ? Phase::idle : Phase::open, now);
    }
  }

  void expire(Time now) noexcept {
    using Closure = ProxyConnectionPolicy::Closure;
    switch (policy_.expired(now)) {
    case Closure::head_timeout:
      handshake_.expire();
      closed_ = true;
      break;
    case Closure::establishment_timeout:
      if (transport_.opened() || handshake_.state() != Handshake::State::establishing) {
        counters_.record(ProxyCounter::establish_timeout);
        closed_ = true;
      } else {
        handshake_.expire();
        enter(Phase::closing, now);
      }
      break;
    case Closure::half_closed_timeout:
      closed_ = true;
      break;
    default:
      break;
    }
  }

  SocketInterest interest(TlsSide side) const noexcept {
    if (transport_.opened()) {
      return transport_.interest(side);
    }
    if (side == TlsSide::child) {
      return {.readable = handshake_.wantsChildRead(), .writable = handshake_.wantsChildWrite()};
    }
    return {.writable = handshake_.wantsOriginWrite()};
  }

  int descriptor(TlsSide side) const noexcept {
    return side == TlsSide::child ? handshake_.childDescriptor() : handshake_.originDescriptor();
  }

  std::size_t originAttempt() const noexcept {
    return handshake_.originAttempt();
  }

  bool closed() const noexcept {
    return closed_;
  }

  bool buffered() const noexcept {
    return transport_.buffered();
  }

  std::optional<Time> deadline() const noexcept {
    return handshake_.deadline();
  }

  const ProxyConnectionPolicy &policy() const noexcept {
    return policy_;
  }

private:
  using Handshake = ConnectHandshake<Memory, Resolver>;
  using Phase = ProxyConnectionPolicy::Phase;

  void enter(Phase phase, Time now) noexcept {
    if (policy_.phase() != phase) {
      policy_.enter(phase, now);
      policy_.touch(now);
    }
  }

  ProxyCounters &counters_;
  Handshake handshake_;
  ConnectionTransport<Memory> transport_;
  ProxyConnectionPolicy policy_;
  std::optional<ConnectionObservation<Memory>> observation_;
  bool closed_ = false;
};

}
