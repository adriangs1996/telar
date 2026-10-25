#pragma once

#include "../metrics/host_sample.hpp"

namespace telar::runtime {

class NativeHostMetrics {
public:
  std::optional<HostCounters> read() noexcept;
};

static_assert(HostMetricsProbe<NativeHostMetrics>);

}
