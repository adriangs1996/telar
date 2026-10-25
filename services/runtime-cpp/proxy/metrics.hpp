#pragma once

#include "counters.hpp"

namespace telar::runtime {

struct ProxyMetrics {
  std::array<std::uint64_t, ProxyCounters::capacity> counters{};
  std::uint32_t active_connections = 0;
  std::uint64_t connection_limit_drops = 0;

  std::uint64_t read(ProxyCounter counter) const noexcept {
    return counters[static_cast<std::size_t>(counter)];
  }
};

}
