export module telar.gui.foundation.core:metric_levels;

import std;

import telar.wire.vocabulary;
import telar.base.ds;

// Interface: core/metric_levels.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    enum class BarMetric : std::uint8_t {
      cpu,
      memory,
      battery,
    };

    enum class MetricSeverity : std::uint8_t {
      normal,
      warning,
      danger,
    };

    // The thresholds that turn a host metric into a warning or a danger.
    struct MetricLevels {
      static constexpr std::uint8_t cpu_warning = 90;
      static constexpr std::uint8_t cpu_danger = 98;
      static constexpr std::uint8_t memory_warning = 85;
      static constexpr std::uint8_t memory_danger = 95;
      static constexpr std::uint8_t battery_warning = 20;
      static constexpr std::uint8_t battery_danger = 10;

      [[nodiscard]] static bool available(BarMetric metric, const SystemMetrics& sample) noexcept;

      // How full the metric is, 0..100: memory in use of the total, or the battery's charge.
      [[nodiscard]] static std::uint8_t percent(BarMetric metric, const SystemMetrics& sample) noexcept;

      // The severity the thresholds give. `margin` moves every threshold that many
      // points away from the current value, so a level is kept until the value has
      // clearly left it.
      [[nodiscard]] static MetricSeverity severity(BarMetric metric, const SystemMetrics& sample, int margin = 0) noexcept;
    };

    // Each metric's severity, debounced: a CPU or memory peak must last
    // `confirm_samples` samples before it raises the level, and a level falls only
    // once the value is `release_margin` points past its threshold. The battery
    // moves slowly, so its rises are immediate.
    class MetricAlerts {
    public:
      static constexpr std::uint8_t confirm_samples = 3;
      static constexpr int release_margin = 5;

      void update(const SystemMetrics& sample) noexcept;

      [[nodiscard]] MetricSeverity severity(BarMetric metric) const noexcept;

    private:
      struct State {
        MetricSeverity current = MetricSeverity::normal;
        MetricSeverity pending = MetricSeverity::normal;
        std::uint8_t pending_count = 0;
      };

      ds::Array<State, 3> states_{};
    };

  }
}
