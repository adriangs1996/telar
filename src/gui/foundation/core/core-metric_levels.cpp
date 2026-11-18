module telar.gui.foundation.core;

import std;

import telar.tbc;
import telar.wire.vocabulary;

namespace telar::gui::inline foundation::inline core {

  bool MetricLevels::available(BarMetric metric, const SystemMetrics& sample) noexcept {
    return sample.revision != 0 && (metric != BarMetric::battery || sample.has_battery);
  }

  std::uint8_t MetricLevels::percent(BarMetric metric, const SystemMetrics& sample) noexcept {
    switch (metric) {
    case BarMetric::cpu:
      return sample.cpu_percent;
    case BarMetric::memory:
      if (sample.memory_total_decigib == 0) {
        return 0;
      }

      return static_cast<std::uint8_t>(std::min<unsigned>(100, ((sample.memory_used_decigib * 100U) + (sample.memory_total_decigib / 2U)) / sample.memory_total_decigib));
    case BarMetric::battery:
      return sample.battery_percent;
    }

    return 0;
  }

  MetricSeverity MetricLevels::severity(BarMetric metric, const SystemMetrics& sample, int margin) noexcept {
    if (!available(metric, sample) || (metric == BarMetric::memory && sample.memory_total_decigib == 0)) {
      return MetricSeverity::normal;
    }

    const int value = percent(metric, sample);
    const auto rising = [&](int warning, int danger) noexcept {
      return value + margin >= danger ? MetricSeverity::danger : value + margin >= warning ? MetricSeverity::warning
                                                                                           : MetricSeverity::normal;
    };

    switch (metric) {
    case BarMetric::cpu:
      return rising(cpu_warning, cpu_danger);
    case BarMetric::memory:
      return rising(memory_warning, memory_danger);
    case BarMetric::battery:
      return value - margin <= battery_danger ? MetricSeverity::danger : value - margin <= battery_warning ? MetricSeverity::warning
                                                                                                           : MetricSeverity::normal;
    }

    return MetricSeverity::normal;
  }

  void MetricAlerts::update(const SystemMetrics& sample) noexcept {
    for (std::size_t index = 0; index < states_.size(); ++index) {
      const auto metric = static_cast<BarMetric>(index);
      auto& state = states_.atMut(index);

      if (!MetricLevels::available(metric, sample)) {
        state = {};
        continue;
      }

      const auto raw = MetricLevels::severity(metric, sample);
      if (raw > state.current) {
        state.pending_count = raw == state.pending ? state.pending_count + 1 : 1;
        state.pending = raw;
        if (metric == BarMetric::battery || state.pending_count >= confirm_samples) {
          state.current = raw;
          state.pending_count = 0;
        }

        continue;
      }

      state.pending_count = 0;
      state.current = std::min(state.current, MetricLevels::severity(metric, sample, release_margin));
    }
  }

  MetricSeverity MetricAlerts::severity(BarMetric metric) const noexcept {
    return states_[static_cast<std::size_t>(metric)].current;
  }

}
