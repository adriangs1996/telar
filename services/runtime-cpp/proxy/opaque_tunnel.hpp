#pragma once

#include "../platform/tunnel_sockets.hpp"
#include "duplex_relay.hpp"

namespace telar::runtime {

class OpaqueTunnel {
public:
  explicit OpaqueTunnel(TunnelSockets sockets) noexcept : sockets_(sockets) {}

  bool advance(TunnelReadiness readiness) noexcept {
    SocketStream child{sockets_.child};
    SocketStream origin{sockets_.origin};
    return relay_.advance(child, origin, readiness);
  }

  bool finished() const noexcept { return relay_.finished(); }
  bool halfClosed() const noexcept { return relay_.halfClosed(); }
  SocketInterest childInterest() const noexcept { return relay_.childInterest(); }
  SocketInterest originInterest() const noexcept { return relay_.originInterest(); }

private:
  static constexpr std::size_t relay_buffer_capacity = 32 * 1024;
  TunnelSockets sockets_;
  DuplexRelay<relay_buffer_capacity> relay_;
};

}
