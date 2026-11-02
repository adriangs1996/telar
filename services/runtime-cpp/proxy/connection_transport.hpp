#pragma once

#include "connect_handshake.hpp"
#include "plain_tunnel.hpp"
#include "tls_tunnel.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ConnectionTransport {
public:
  explicit ConnectionTransport(Memory &memory) noexcept
      : memory_(memory), flow_(nullptr, AllocationDeleter<FlowState, Memory>{memory}), plain_(nullptr, AllocationDeleter<PlainTunnel<Memory>, Memory>{memory}), tls_(nullptr, AllocationDeleter<TlsTunnel<Memory>, Memory>{memory}) {}

  template <HostnameResolver Resolver>
  void open(const TlsInterception<Memory> &interception, const ConnectHandshake<Memory, Resolver> &handshake, ConnectionObservation<Memory> observation) {
    if (observation.flows) {
      flow_ = makeOwned<FlowState>(memory_);
      flow_->open(observation.flows, observation.identity, handshake.childDescriptor(), handshake.originDescriptor(), handshake.hostname());
    }
    const TunnelSockets sockets{handshake.childDescriptor(), handshake.originDescriptor()};
    if (handshake.intercept()) {
      tls_ = makeOwned<TlsTunnel<Memory>>(memory_, memory_, interception, sockets, handshake.hostname(), observation, flow_.get());
    } else {
      plain_ = makeOwned<PlainTunnel<Memory>>(memory_, memory_, sockets, handshake.hostname(), observation, flow_.get());
      observation.counters.record(ProxyCounter::passthrough_connection);
    }
  }

  bool opened() const noexcept { return plain_ || tls_; }

  bool advance(TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.relayTunnel");
    return plain_ ? plain_->advance(readiness) : tls_->advance(readiness);
  }

  bool established() const noexcept { return plain_ || tls_->established(); }
  bool finished() const noexcept { return (flow_ && flow_->rejected()) || (plain_ ? plain_->finished() : tls_->finished()); }
  bool halfClosed() const noexcept { return plain_ ? plain_->halfClosed() : tls_->halfClosed(); }
  bool idle() const noexcept { return plain_ ? plain_->idle() : tls_ && tls_->idle(); }
  std::uint32_t inflight() const noexcept { return plain_ ? plain_->inflight() : tls_ ? tls_->inflight() : 0; }
  bool buffered() const noexcept { return plain_ ? plain_->buffered() : tls_ && tls_->buffered(); }

  SocketInterest interest(TlsSide side) const noexcept {
    if (plain_) {
      return plain_->interest(side);
    }
    return tls_->interest(side);
  }

  std::optional<traffic::FlowControl::Time> deadline() const noexcept {
    const auto flow = flow_ ? flow_->deadline() : std::nullopt;
    const auto tls = plain_ ? plain_->deadline() : tls_ ? tls_->deadline() : std::nullopt;
    return flow && tls ? std::min(*flow, *tls) : flow ? flow : tls;
  }
  void reason(std::string_view value) noexcept { if (flow_) { flow_->reason(value); } }
  void error(std::string_view value) noexcept { if (flow_) { flow_->error(value); } }

private:
  Memory &memory_;
  Owned<FlowState, Memory> flow_;
  Owned<PlainTunnel<Memory>, Memory> plain_;
  Owned<TlsTunnel<Memory>, Memory> tls_;
};

}
