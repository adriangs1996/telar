#pragma once

#include "../exchange_capture/producer.hpp"
#include "counters.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
struct ConnectionObservation {
  ProxyCounters &counters;
  CaptureProducer<Memory> *captures;
  std::uint64_t identity;
};

}
