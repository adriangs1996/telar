#pragma once

#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "machines/machine_row.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

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

  [[nodiscard]] static std::string_view glyph(MachinePhase phase, bool attention) noexcept {
    if (attention || phase == MachinePhase::connected) {
      return "●";
    }

    switch (phase) {
    case MachinePhase::connecting:
      return "◌";
    case MachinePhase::lost:
    case MachinePhase::failed:
      return "✕";
    case MachinePhase::stopped:
      return "○";
    case MachinePhase::connected:
      break;
    }

    return {};
  }

  [[nodiscard]] static PaletteRole glyphInk(MachinePhase phase, bool attention) noexcept {
    if (attention) {
      return PaletteRole::yellow;
    }

    switch (phase) {
    case MachinePhase::connected:
      return PaletteRole::green;
    case MachinePhase::connecting:
      return PaletteRole::overlay1;
    case MachinePhase::lost:
      return PaletteRole::peach;
    case MachinePhase::failed:
      return PaletteRole::red;
    case MachinePhase::stopped:
      return PaletteRole::overlay0;
    }

    return PaletteRole::text;
  }

  [[nodiscard]] static std::string_view phaseName(MachinePhase phase) noexcept {
    switch (phase) {
    case MachinePhase::connected:
      return "connected";
    case MachinePhase::connecting:
      return "connecting";
    case MachinePhase::lost:
      return "lost";
    case MachinePhase::failed:
      return "failed";
    case MachinePhase::stopped:
      return "stopped";
    }

    return {};
  }

  [[nodiscard]] static CpuText cpu(MachinePhase phase, std::optional<std::uint8_t> percent) {
    CpuText value;
    if (phase == MachinePhase::connected && percent) {
      value.appendDecimal(*percent);
      value.append("%");
    }

    return value;
  }

  [[nodiscard]] static float width(const ChromeMetrics &chrome, Widths parts) noexcept {
    return parts.glyph + chrome.px(part_gap) + parts.label + (parts.cpu > 0 ? chrome.px(part_gap) + parts.cpu : 0);
  }

  [[nodiscard]] static Geometry geometry(Rect area, const ChromeMetrics &chrome, Widths parts) noexcept {
    Geometry result;
    result.bounds = {.x = area.x, .y = area.y, .width = width(chrome, parts), .height = area.height};
    result.glyph = {.x = area.x, .y = area.y, .width = parts.glyph, .height = area.height};
    result.label = {.x = result.glyph.right() + chrome.px(part_gap), .y = area.y, .width = parts.label, .height = area.height};
    if (parts.cpu > 0) {
      result.cpu = {.x = result.label.right() + chrome.px(part_gap), .y = area.y, .width = parts.cpu, .height = area.height};
    }

    return result;
  }
};

}
