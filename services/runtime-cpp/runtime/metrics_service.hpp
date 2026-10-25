#pragma once

#include "../metrics/host_sampler.hpp"
#include "../model/client.hpp"
#include "../platform/observation_worker.hpp"

namespace telar::runtime {

template <HostMetricsProbe Probe>
class HostMetricsReader {
public:
  using Request = HostSampler;
  using Result = HostSampler;

  explicit HostMetricsReader(Probe &probe) noexcept
      : probe_(probe) {}

  Result observe(const Request &previous) noexcept {
    auto next = previous;
    TELAR_DIAGNOSTIC(const auto started = std::chrono::steady_clock::now());
    if (const auto counters = probe_.read()) {
      next.apply(*counters);
    }

    TELAR_DIAGNOSTIC(next.recordSample(started, std::chrono::steady_clock::now()));

    return next;
  }

  void stop() noexcept {}

private:
  Probe &probe_;
};

template <HostMetricsProbe Probe>
class HostMetricsService {
public:
  using Clock = std::chrono::steady_clock;
  static constexpr auto sample_interval = std::chrono::seconds{2};

  explicit HostMetricsService(Probe &probe, Clock::time_point started = Clock::now())
      : reader_(probe),
        worker_(reader_),
        next_sample_(started + sample_interval) {}

  std::chrono::nanoseconds tick(Clock::time_point now) {
    collect();
    if (now >= next_sample_) {
      next_sample_ = now + sample_interval;
      worker_.submit(sampler_);
    }

    return next_sample_ - now;
  }

  void collect() {
    worker_.collect([this](const HostSampler &sample) { sampler_ = sample; });
  }

  template <Allocator Memory>
  void publish(ClientSession<Memory> &client) const {
    if (!client.subscribed || client.metrics_revision == sampler_.revision()) {
      return;
    }

    if (const auto &values = sampler_.latest()) {
      client.connection.send(SystemMetrics{
          .revision = sampler_.revision(),
          .cpu_percent = values->cpu_percent,
          .memory_used_decigib = values->memory_used_decigib,
          .has_battery = values->battery_percent.has_value(),
          .battery_percent = values->battery_percent.value_or(0),
          .cpu_count = values->cpu_count,
          .memory_total_decigib = values->memory_total_decigib,
      });
    }

    client.metrics_revision = sampler_.revision();
  }

  int descriptor() const noexcept {
    return worker_.descriptor();
  }

#if TELAR_DIAGNOSTICS
  const diagnostics::SystemCounters &diagnostics() const noexcept {
    return sampler_.diagnostics();
  }
#endif

private:
  HostMetricsReader<Probe> reader_;
  ObservationWorker<HostMetricsReader<Probe>> worker_;
  HostSampler sampler_;
  Clock::time_point next_sample_;
};

}
