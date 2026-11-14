module;

#include <cstdint>

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.metrics.host_sampler;

import std;

export import telar.runtime.diagnostics.runtime_counters;
export import telar.runtime.platform.host_metrics;
import telar.base.diagnostics;
import telar.runtime.diagnostics.line;

// Interface: metrics/host_sample.cppm
export {
  namespace telar::runtime {

    struct HostValues {
      std::uint8_t cpu_percent;
      std::uint16_t memory_used_decigib;
      std::uint16_t memory_total_decigib;
      std::uint16_t cpu_count;
      std::optional<std::uint8_t> battery_percent;
      bool operator==(const HostValues&) const = default;
    };

  }
}

// Interface: metrics/host_sampler.cppm
export {
  namespace telar::runtime {

    class HostSampler {
    public:
      void apply(const HostCounters& counters) noexcept;

      const std::optional<HostValues>& latest() const noexcept;

      std::uint64_t revision() const noexcept;

#if TELAR_DIAGNOSTICS
      void recordSample(std::chrono::steady_clock::time_point started, std::chrono::steady_clock::time_point captured) noexcept;

      const diagnostics::SystemCounters& diagnostics() const noexcept;
#endif

    private:
      std::uint8_t cpuPercent(const HostCounters& counters) const noexcept;

      static std::uint16_t decigib(std::uint64_t bytes) noexcept;

      std::optional<HostValues> latest_;
      std::uint64_t revision_ = 1;
      std::uint64_t previous_busy_ = 0;
      std::uint64_t previous_total_ = 0;
#if TELAR_DIAGNOSTICS
      diagnostics::SystemCounters diagnostics_;
#endif
    };

  }
}
