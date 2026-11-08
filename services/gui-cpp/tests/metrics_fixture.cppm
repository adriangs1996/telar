module;
#include <cstdint>

export module telar.gui.tests.metrics_fixture;

import std;
export import telar.client.protocol;

export {
namespace telar::gui::test {

inline SystemMetrics hostSample(std::uint64_t revision, std::uint8_t cpu_percent, std::uint16_t memory_used = 0, std::optional<std::uint8_t> battery = std::nullopt) {
  return {
      .revision = revision,
      .cpu_percent = cpu_percent,
      .memory_used_decigib = memory_used,
      .has_battery = battery.has_value(),
      .battery_percent = battery.value_or(0),
      .cpu_count = 0,
      .memory_total_decigib = 0,
  };
}

}
}
