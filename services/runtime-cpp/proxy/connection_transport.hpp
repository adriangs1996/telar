#pragma once

#include "connect_handshake.hpp"
#include "opaque_tunnel.hpp"
#include "tls_tunnel.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ConnectionTransport {
public:
  explicit ConnectionTransport(Memory &memory) noexcept
      : memory_(memory), opaque_(nullptr, AllocationDeleter<OpaqueTunnel, Memory>{memory}), tls_(nullptr, AllocationDeleter<TlsTunnel<Memory>, Memory>{memory}) {}

  template <HostnameResolver Resolver>
  void open(const TlsInterception<Memory> &interception, const ConnectHandshake<Memory, Resolver> &handshake, ConnectionObservation<Memory> observation) {
    const TunnelSockets sockets{handshake.childDescriptor(), handshake.originDescriptor()};
    if (handshake.intercept()) {
      tls_ = makeOwned<TlsTunnel<Memory>>(memory_, memory_, interception, sockets, handshake.hostname(), observation);
    } else {
      opaque_ = makeOwned<OpaqueTunnel>(memory_, sockets);
      observation.counters.record(ProxyCounter::passthrough_connection);
    }
  }

  bool opened() const noexcept { return opaque_ || tls_; }

  bool advance(TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.relayTunnel");
    return opaque_ ? opaque_->advance(readiness) : tls_->advance(readiness);
  }

  bool established() const noexcept { return opaque_ || tls_->established(); }
  bool finished() const noexcept { return opaque_ ? opaque_->finished() : tls_->finished(); }
  bool halfClosed() const noexcept { return opaque_ ? opaque_->halfClosed() : tls_->halfClosed(); }
  bool idle() const noexcept { return tls_ && tls_->idle(); }
  std::uint32_t inflight() const noexcept { return tls_ ? tls_->inflight() : 0; }
  bool buffered() const noexcept { return tls_ && tls_->buffered(); }

  SocketInterest interest(TlsSide side) const noexcept {
    if (opaque_) {
      return side == TlsSide::child ? opaque_->childInterest() : opaque_->originInterest();
    }
    return tls_->interest(side);
  }

private:
  Memory &memory_;
  Owned<OpaqueTunnel, Memory> opaque_;
  Owned<TlsTunnel<Memory>, Memory> tls_;
};

}
