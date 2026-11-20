module;
#include "tbc/annotations.hpp"

// The status bar: the host's metrics the runtime samples, with the CPU's history and the alerts
// each metric raises, and the mode bar's words and geometry.
export module telar.gui.features.status_bar;

export import :geometry;
export import :history;
export import :metrics;
export import :modes;

import std;
import telar.tbc;

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
  // Inline, as the bar reads it whenever it draws.
  class TBC_HOT_PATH HostMetrics {
  public:
    inline explicit HostMetrics(tbc::view<const State&, tbc::lt::a> state) noexcept
        : state_(&state) {}

    [[nodiscard]] inline tbc::view<const SystemMetrics&, tbc::lt::a> sample() const noexcept;

    [[nodiscard]] inline tbc::view<const CpuHistory&, tbc::lt::a> history() const noexcept;

    [[nodiscard]] inline MetricSeverity severity(BarMetric metric) const noexcept;

  private:
    tbc::view<const State*, tbc::lt::a> state_;
  };

  // A sample from the runtime: false when it is not newer than the one the bar shows.
  [[nodiscard]] bool receive(State& state, const SystemMetrics& sample);

  [[nodiscard]] TBC_HOT_PATH inline HostMetrics metrics(const State& state) noexcept {
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

  inline tbc::view<const SystemMetrics&, tbc::lt::a> HostMetrics::sample() const noexcept {
    return Access::sample(*state_);
  }

  inline tbc::view<const CpuHistory&, tbc::lt::a> HostMetrics::history() const noexcept {
    return Access::history(*state_);
  }

  inline MetricSeverity HostMetrics::severity(BarMetric metric) const noexcept {
    return Access::alerts(*state_).severity(metric);
  }

}
