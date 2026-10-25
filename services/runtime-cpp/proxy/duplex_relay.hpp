#pragma once

#include "relay_direction.hpp"
#include "socket_interest.hpp"

namespace telar::runtime {

template <std::size_t BufferCapacity = RelayDirection<>::capacity>
class DuplexRelay {
  using Direction = RelayDirection<BufferCapacity>;

public:
  template <ByteStream Child, ByteStream Origin>
  bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    const bool outgoing = transfer(outbound_, child, origin, readiness.child, readiness.origin);
    const bool incoming = transfer(inbound_, origin, child, readiness.origin, readiness.child);
    return outgoing || incoming;
  }

  bool finished() const noexcept {
    return outbound_.finished() && inbound_.finished();
  }

  bool halfClosed() const noexcept {
    return outbound_.finished() || inbound_.finished();
  }

  bool readsChild() const noexcept { return outbound_.wantsRead(); }
  bool readsOrigin() const noexcept { return inbound_.wantsRead(); }

  SocketInterest childInterest() const noexcept {
    SocketInterest interest;
    interest.include(outbound_.sourceInterest());
    interest.include(inbound_.destinationInterest());
    return interest;
  }

  SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    interest.include(inbound_.sourceInterest());
    interest.include(outbound_.destinationInterest());
    return interest;
  }

private:
  template <ByteStream Source, ByteStream Destination>
  static bool transfer(Direction &direction, Source &source, Destination &destination, SocketInterest source_ready, SocketInterest destination_ready) noexcept {
    if (!source_ready.satisfies(direction.sourceInterest()) && !destination_ready.satisfies(direction.destinationInterest())) {
      return false;
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds; ++round) {
      const auto progress = direction.advance(source, destination);
      active = active || progress.active();
      if (direction.wantsWrite() || progress.read < Direction::capacity) {
        break;
      }
    }
    return active;
  }

  static constexpr std::size_t maximum_transfer_bytes = 128 * 1024;
  static_assert(BufferCapacity <= maximum_transfer_bytes);
  static constexpr std::size_t maximum_rounds = maximum_transfer_bytes / BufferCapacity;
  Direction outbound_;
  Direction inbound_;
};

}
