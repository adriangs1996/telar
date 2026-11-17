module telar.gui.features.status_bar;

import std;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::features::status_bar {

  bool BarMetrics::available(BarMetric metric, const SystemMetrics& sample) noexcept {
    return MetricLevels::available(metric, sample);
  }

  std::string_view BarMetrics::glyph(BarMetric metric) noexcept {
    switch (metric) {
    case BarMetric::cpu:
      return "\uf4bc";
    case BarMetric::memory:
      return "\uefc5";
    case BarMetric::battery:
      return {};
    }

    return {};
  }

  BarMetrics::Value BarMetrics::value(BarMetric metric, const SystemMetrics& sample) {
    Value result;

    if (!available(metric, sample)) {
      return result;
    }

    switch (metric) {
    case BarMetric::cpu:
      result.appendDecimal(sample.cpu_percent);
      result.append("%");
      break;
    case BarMetric::memory:
      result.appendDecimal(static_cast<unsigned>(sample.memory_used_decigib / tenths_per_unit));
      result.append(".");
      result.appendDecimal(static_cast<unsigned>(sample.memory_used_decigib % tenths_per_unit));
      result.append(" GB");
      break;
    case BarMetric::battery:
      result.appendDecimal(sample.battery_percent);
      result.append("%");
      break;
    }

    return result;
  }

  std::uint8_t BarMetrics::percent(BarMetric metric, const SystemMetrics& sample) noexcept {
    return MetricLevels::percent(metric, sample);
  }

  MetricSeverity BarMetrics::severity(BarMetric metric, const SystemMetrics& sample, int margin) noexcept {
    return MetricLevels::severity(metric, sample, margin);
  }

  PaletteRole BarMetrics::ink(MetricSeverity severity) noexcept {
    switch (severity) {
    case MetricSeverity::normal:
      return PaletteRole::text;
    case MetricSeverity::warning:
      return PaletteRole::yellow;
    case MetricSeverity::danger:
      return PaletteRole::red;
    }

    return PaletteRole::text;
  }

  PaletteRole BarMetrics::ink(BarMetric metric, const SystemMetrics& sample) noexcept {
    return ink(severity(metric, sample));
  }

}
