export module telar.gui.presentation.history_filter_geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.text;

import telar.gui.machines.picker;
import telar.wire.vocabulary;

// Interface: presentation/bar_metrics.cppm
export {
  namespace telar::gui {

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

// Interface: presentation/machine_facts.cppm
export {
  namespace telar::gui {

    struct MachineFacts {
      static constexpr float machine_gap = 12;
      static constexpr float part_gap = 5;
      static constexpr std::size_t cpu_capacity = 8;
      using CpuText = BoundedText<cpu_capacity>;

      struct Widths {
        float glyph = 0;
        float label = 0;
        float cpu = 0;
      };

      struct Geometry {
        Rect bounds;
        Rect glyph;
        Rect label;
        Rect cpu;
      };

      [[nodiscard]] static std::string_view glyph(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static PaletteRole glyphInk(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static std::string_view phaseName(MachinePhase phase) noexcept;
      [[nodiscard]] static CpuText cpu(MachinePhase phase, std::optional<std::uint8_t> percent);
      [[nodiscard]] static float width(const ChromeMetrics& chrome, Widths parts) noexcept;
      [[nodiscard]] static Geometry geometry(Rect area, const ChromeMetrics& chrome, Widths parts) noexcept;
    };

  }
}
