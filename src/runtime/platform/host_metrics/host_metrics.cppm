export module telar.runtime.platform.host_metrics;

import std;
import telar.base.ds;

// Interface: platform/host_metrics.cppm
export {
  namespace telar::runtime {

    struct HostCounters {
      std::uint64_t busy_ticks;
      std::uint64_t total_ticks;
      std::uint64_t memory_used_bytes;
      std::uint64_t memory_total_bytes;
      std::uint16_t cpu_count;
      ds::Option<std::uint8_t> battery_percent;
    };

    template <typename Probe>
    concept HostMetricsProbe = requires(Probe& probe) {
      { probe.read() } noexcept -> std::same_as<ds::Option<HostCounters>>;
    };

    class NativeHostMetrics {
    public:
      ds::Option<HostCounters> read() noexcept;
    };

    static_assert(HostMetricsProbe<NativeHostMetrics>);

  }
}
