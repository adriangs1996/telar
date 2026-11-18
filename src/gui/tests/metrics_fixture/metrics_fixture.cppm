module;
#include <cstdint>

export module telar.gui.tests.metrics_fixture;

import std;
import telar.gui.features.status_bar;
import telar.gui.foundation.core;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

export {
  namespace telar::gui::test {

    inline SystemMetrics hostSample(std::uint64_t revision, std::uint8_t cpu_percent, std::uint16_t memory_used = 0, ds::Option<std::uint8_t> battery = ds::none) {
      return {
          .revision = revision,
          .cpu_percent = cpu_percent,
          .memory_used_decigib = memory_used,
          .has_battery = battery.hasValue(),
          .battery_percent = battery.valueOr(0),
          .cpu_count = 0,
          .memory_total_decigib = 0,
      };
    }

    // The host's metrics as a session keeps them, driven through the status bar's use cases
    // under the names the assertions read.
    class HostMetricsState {
    public:
      bool update(const SystemMetrics& sample) {
        return features::status_bar::receive(state_, sample);
      }

      [[nodiscard]] features::status_bar::HostMetrics view() const noexcept {
        return features::status_bar::metrics(state_);
      }

      [[nodiscard]] const SystemMetrics& sample() const noexcept {
        return view().sample();
      }

      [[nodiscard]] const features::status_bar::CpuHistory& history() const noexcept {
        return view().history();
      }

      [[nodiscard]] MetricSeverity severity(BarMetric metric) const noexcept {
        return view().severity(metric);
      }

    private:
      features::status_bar::State state_;
    };

  }
}
