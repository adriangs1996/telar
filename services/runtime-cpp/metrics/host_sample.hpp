#pragma once

#include <concepts>
#include <cstdint>
#include <optional>

namespace telar::runtime {

struct HostCounters {
  std::uint64_t busy_ticks;
  std::uint64_t total_ticks;
  std::uint64_t memory_used_bytes;
  std::uint64_t memory_total_bytes;
  std::uint16_t cpu_count;
  std::optional<std::uint8_t> battery_percent;
};

struct HostValues {
  std::uint8_t cpu_percent;
  std::uint16_t memory_used_decigib;
  std::uint16_t memory_total_decigib;
  std::uint16_t cpu_count;
  std::optional<std::uint8_t> battery_percent;
  bool operator==(const HostValues &) const = default;
};

template <typename Probe>
concept HostMetricsProbe = requires(Probe &probe) {
  { probe.read() } noexcept -> std::same_as<std::optional<HostCounters>>;
};

}
