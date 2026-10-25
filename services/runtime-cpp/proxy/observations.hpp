#pragma once

#include "connection_observation.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ProxyObservations {
public:
  explicit ProxyObservations(Memory &memory, ProxyCaptureLimits limits) : captures(memory, limits), capture_enabled_(limits.enabled) {}

  ConnectionObservation<Memory> connection() noexcept {
    return {counters, capture_enabled_ ? &captures : nullptr, next_connection_++};
  }

  ProxyCounters counters;
  CaptureProducer<Memory> captures;

private:
  bool capture_enabled_;
  std::uint64_t next_connection_ = 1;
};

}
