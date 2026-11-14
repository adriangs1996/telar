module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.metrics.host_sampler;

namespace telar::runtime {

  void HostSampler::apply(const HostCounters& counters) noexcept {
    const HostValues next{
        .cpu_percent = cpuPercent(counters),
        .memory_used_decigib = decigib(counters.memory_used_bytes),
        .memory_total_decigib = decigib(counters.memory_total_bytes),
        .cpu_count = counters.cpu_count,
        .battery_percent = counters.battery_percent,
    };

    previous_busy_ = counters.busy_ticks;
    previous_total_ = counters.total_ticks;
    if (latest_ == next) {
      return;
    }

    latest_ = next;
    ++revision_;
    if (revision_ == 0) {
      revision_ = 1;
    }
  }

  const std::optional<HostValues>& HostSampler::latest() const noexcept {
    return latest_;
  }

  std::uint64_t HostSampler::revision() const noexcept {
    return revision_;
  }

#if TELAR_DIAGNOSTICS
  void HostSampler::recordSample(std::chrono::steady_clock::time_point started, std::chrono::steady_clock::time_point captured) noexcept {
    diagnostics_.sample.observe(std::chrono::duration_cast<std::chrono::nanoseconds>(captured - started).count());
    diagnostics_.captured = captured;
  }

  const diagnostics::SystemCounters& HostSampler::diagnostics() const noexcept {
    return diagnostics_;
  }
#endif

  std::uint8_t HostSampler::cpuPercent(const HostCounters& counters) const noexcept {
    if (previous_total_ == 0 || counters.total_ticks <= previous_total_) {
      return 0;
    }

    const auto busy = counters.busy_ticks - std::min(counters.busy_ticks, previous_busy_);
    const auto total = counters.total_ticks - previous_total_;

    return static_cast<std::uint8_t>(std::min<__uint128_t>(100, static_cast<__uint128_t>(busy) * 100 / total));
  }

  std::uint16_t HostSampler::decigib(std::uint64_t bytes) noexcept {
    constexpr std::uint64_t bytes_per_gib = std::uint64_t{1} << 30;
    const auto tenths = static_cast<__uint128_t>(bytes) * 10 / bytes_per_gib;

    return static_cast<std::uint16_t>(std::min<__uint128_t>(tenths, std::numeric_limits<std::uint16_t>::max()));
  }

}
