// What the bar shows of each host metric: whether it is known, its glyph, its text, its
// percent and the ink its severity takes.
export module telar.gui.features.status_bar:metrics;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.wire.vocabulary;

// Interface: presentation/bar_metrics.cppm
export {
  namespace telar::gui::features::status_bar {

    struct BarMetrics {
      static constexpr std::size_t value_capacity = 16;
      static constexpr std::uint8_t cpu_warning = MetricLevels::cpu_warning;
      static constexpr std::uint8_t cpu_danger = MetricLevels::cpu_danger;
      static constexpr std::uint8_t memory_warning = MetricLevels::memory_warning;
      static constexpr std::uint8_t memory_danger = MetricLevels::memory_danger;
      static constexpr std::uint8_t battery_warning = MetricLevels::battery_warning;
      static constexpr std::uint8_t battery_danger = MetricLevels::battery_danger;
      static constexpr std::uint16_t tenths_per_unit = 10;
      using Value = BoundedText<value_capacity>;

      [[nodiscard]] static bool available(BarMetric metric, const SystemMetrics& sample) noexcept;
      [[nodiscard]] static std::string_view glyph(BarMetric metric) noexcept;
      [[nodiscard]] static Value value(BarMetric metric, const SystemMetrics& sample);
      [[nodiscard]] static std::uint8_t percent(BarMetric metric, const SystemMetrics& sample) noexcept;
      [[nodiscard]] static MetricSeverity severity(BarMetric metric, const SystemMetrics& sample, int margin = 0) noexcept;
      [[nodiscard]] static PaletteRole ink(MetricSeverity severity) noexcept;
      [[nodiscard]] static PaletteRole ink(BarMetric metric, const SystemMetrics& sample) noexcept;
    };

  }
}
