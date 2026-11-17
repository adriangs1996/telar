// The status bar: the host's metrics the runtime samples, with the CPU's history and the alerts
// each metric raises, and the mode bar's words and geometry.
export module telar.gui.features.status_bar;

export import :geometry;
export import :history;
export import :metrics;
export import :modes;

import std;

import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::features::status_bar {

  struct Access;

}

export namespace telar::gui::features::status_bar {

  // The host's metrics as the runtime last sampled them, the CPU's recent samples and the
  // severity each metric settled at. Opaque: only the use cases below reach it.
  class State {
    friend struct Access;

    SystemMetrics sample_{};
    CpuHistory history_;
    MetricAlerts alerts_;
  };

  // What the bar reads of the host's metrics: a view of the state, valid until the next sample.
  class HostMetrics {
  public:
    inline explicit HostMetrics(const State& state) noexcept
        : state_(&state) {}

    [[nodiscard]] inline const SystemMetrics& sample() const noexcept;

    [[nodiscard]] inline const CpuHistory& history() const noexcept;

    [[nodiscard]] inline MetricSeverity severity(BarMetric metric) const noexcept;

  private:
    const State* state_;
  };

  // A sample from the runtime: false when it is not newer than the one the bar shows.
  [[nodiscard]] bool receive(State& state, const SystemMetrics& sample);

  [[nodiscard]] inline HostMetrics metrics(const State& state) noexcept {
    return HostMetrics{state};
  }

}

namespace telar::gui::features::status_bar {

  struct Access {
    [[nodiscard]] static constexpr SystemMetrics& sample(State& state) noexcept {
      return state.sample_;
    }

    [[nodiscard]] static constexpr const SystemMetrics& sample(const State& state) noexcept {
      return state.sample_;
    }

    [[nodiscard]] static constexpr CpuHistory& history(State& state) noexcept {
      return state.history_;
    }

    [[nodiscard]] static constexpr const CpuHistory& history(const State& state) noexcept {
      return state.history_;
    }

    [[nodiscard]] static constexpr MetricAlerts& alerts(State& state) noexcept {
      return state.alerts_;
    }

    [[nodiscard]] static constexpr const MetricAlerts& alerts(const State& state) noexcept {
      return state.alerts_;
    }
  };

  inline const SystemMetrics& HostMetrics::sample() const noexcept {
    return Access::sample(*state_);
  }

  inline const CpuHistory& HostMetrics::history() const noexcept {
    return Access::history(*state_);
  }

  inline MetricSeverity HostMetrics::severity(BarMetric metric) const noexcept {
    return Access::alerts(*state_).severity(metric);
  }

}
