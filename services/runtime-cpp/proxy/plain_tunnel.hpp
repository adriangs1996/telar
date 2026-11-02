#pragma once

#include "application_relay.hpp"
#include "../platform/tunnel_sockets.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class PlainTunnel {
public:
  explicit PlainTunnel(Memory &memory, TunnelSockets sockets, std::string_view hostname, ConnectionObservation<Memory> observation, FlowState *flow) : sockets_(sockets), application_(memory, observation, hostname, flow) {}

  bool advance(TunnelReadiness readiness) noexcept {
    SocketStream child{sockets_.child}, origin{sockets_.origin};
    return application_.advance(child, origin, readiness);
  }
  bool finished() const noexcept { return application_.finished(); }
  bool halfClosed() const noexcept { return application_.halfClosed(); }
  bool idle() const noexcept { return application_.idle(); }
  std::uint32_t inflight() const noexcept { return application_.inflight(); }
  bool buffered() const noexcept { return application_.buffered(); }
  auto deadline() const noexcept { return application_.deadline(); }
  SocketInterest interest(TlsSide side) const noexcept { return application_.interest(side); }
private:
  TunnelSockets sockets_;
  ApplicationRelay<Memory> application_;
};

}
