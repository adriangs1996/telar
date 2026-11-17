module telar.gui.presentation.history_filter_geometry;

import std;

import telar.gui.foundation.core;

namespace telar::gui {

  std::string_view MachineFacts::glyph(MachinePhase phase, bool attention) noexcept {
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

  PaletteRole MachineFacts::glyphInk(MachinePhase phase, bool attention) noexcept {
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

  std::string_view MachineFacts::phaseName(MachinePhase phase) noexcept {
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

  MachineFacts::CpuText MachineFacts::cpu(MachinePhase phase, std::optional<std::uint8_t> percent) {
    CpuText value;

    if (phase == MachinePhase::connected && percent) {
      value.appendDecimal(*percent);
      value.append("%");
    }

    return value;
  }

  float MachineFacts::width(const ChromeMetrics& chrome, Widths parts) noexcept {
    return parts.glyph + chrome.px(part_gap) + parts.label + (parts.cpu > 0 ? chrome.px(part_gap) + parts.cpu : 0);
  }

  MachineFacts::Geometry MachineFacts::geometry(Rect area, const ChromeMetrics& chrome, Widths parts) noexcept {
    Geometry result;

    result.bounds = {.x = area.x, .y = area.y, .width = width(chrome, parts), .height = area.height};
    result.glyph = {.x = area.x, .y = area.y, .width = parts.glyph, .height = area.height};
    result.label = {.x = result.glyph.right() + chrome.px(part_gap), .y = area.y, .width = parts.label, .height = area.height};
    if (parts.cpu > 0) {
      result.cpu = {.x = result.label.right() + chrome.px(part_gap), .y = area.y, .width = parts.cpu, .height = area.height};
    }

    return result;
  }

}
