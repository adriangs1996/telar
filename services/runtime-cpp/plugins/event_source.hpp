#pragma once

#include "effects.hpp"
#include <concepts>

namespace telar::runtime::plugins {

struct TapMetrics {
  std::uint64_t dropped_queue = 0;
  std::uint64_t dropped_bytes = 0;
  std::uint64_t timeouts = 0;
  std::uint64_t disabled = 0;
};

template <typename Source>
concept EventSource = requires(Source &source, void (*consumer)(const EffectBatch &)) {
  { source.descriptor() } noexcept -> std::same_as<int>;
  { source.collect(consumer) } -> std::same_as<void>;
  { source.metrics() } noexcept -> std::same_as<TapMetrics>;
};

struct IgnoreEvents {
  int descriptor() const noexcept { return -1; }
  TapMetrics metrics() const noexcept { return {}; }

  template <typename Consumer>
  void collect(Consumer &&) const noexcept {}
};

}
