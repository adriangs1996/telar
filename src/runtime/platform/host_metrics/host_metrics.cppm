export module telar.runtime.platform.host_metrics;

import std;

// Interface: platform/host_metrics.cppm
export {
  namespace telar::runtime {

    struct HostCounters {
      std::uint64_t busy_ticks;
      std::uint64_t total_ticks;
      std::uint64_t memory_used_bytes;
      std::uint64_t memory_total_bytes;
      std::uint16_t cpu_count;
      std::optional<std::uint8_t> battery_percent;
    };

    template <typename Probe>
    concept HostMetricsProbe = requires(Probe& probe) {
      { probe.read() } noexcept -> std::same_as<std::optional<HostCounters>>;
    };

    class NativeHostMetrics {
    public:
      std::optional<HostCounters> read() noexcept;
    };

    static_assert(HostMetricsProbe<NativeHostMetrics>);

  }
}
