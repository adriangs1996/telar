#pragma once

#include "core/theme_values.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

enum class BarMetric : std::uint8_t {
  cpu,
  memory,
  battery,
};

struct BarMetrics {
  static constexpr std::size_t value_capacity = 16;
  static constexpr std::uint8_t cpu_warning = 90;
  static constexpr std::uint8_t cpu_danger = 98;
  static constexpr std::uint8_t battery_warning = 20;
  static constexpr std::uint8_t battery_danger = 10;
  static constexpr std::uint16_t tenths_per_unit = 10;
  using Value = BoundedText<value_capacity>;

  [[nodiscard]] static bool available(BarMetric metric, const SystemMetrics &sample) noexcept {
    return sample.revision != 0 && (metric != BarMetric::battery || sample.has_battery);
  }

  [[nodiscard]] static std::string_view glyph(BarMetric metric) noexcept {
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

  [[nodiscard]] static Value value(BarMetric metric, const SystemMetrics &sample) {
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

  [[nodiscard]] static PaletteRole ink(BarMetric metric, const SystemMetrics &sample) noexcept {
    if (!available(metric, sample)) {
      return PaletteRole::text;
    }

    switch (metric) {
    case BarMetric::cpu:
      if (sample.cpu_percent >= cpu_danger) {
        return PaletteRole::red;
      }

      return sample.cpu_percent >= cpu_warning ? PaletteRole::yellow : PaletteRole::text;
    case BarMetric::battery:
      if (sample.battery_percent <= battery_danger) {
        return PaletteRole::red;
      }

      return sample.battery_percent <= battery_warning ? PaletteRole::yellow : PaletteRole::text;
    case BarMetric::memory:
      return PaletteRole::text;
    }

    return PaletteRole::text;
  }
};

}
