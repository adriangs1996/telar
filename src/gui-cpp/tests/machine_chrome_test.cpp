#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <variant>
#include <algorithm>
#include <cmath>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <span>
#include "telar_client/codecs/telar_wire.hpp"
#include <exception>
#include <iostream>



import telar.gui.core.metrics;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.history_filter_geometry;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

void colorNamesKeepWrittenSemantics() {
  const auto role = ColorName::parse("PaNeL-Bg");
  require(role && std::get<PaletteRole>(*role) == PaletteRole::panel_bg, "machine colors normalize ASCII case and role separators");
  const auto inherited = ColorName::parse("DeFaUlT");
  require(inherited && std::get<CellColor>(*inherited).kind == CellColor::Kind::default_color, "an explicit default remains a default color, rather than an accent alias");
  const auto literal = ColorName::parse("#aBcDeF");
  const std::array<Byte, 3> expected{0xab, 0xcd, 0xef};
  require(literal && std::get<CellColor>(*literal).channels == expected, "hexadecimal machine ink preserves every byte");
  const auto separated = ColorName::parse("#ff__ff");
  const std::array<Byte, 3> cyan{0, 0xff, 0xff};
  require(separated && std::get<CellColor>(*separated).channels == cyan, "the original hexadecimal parser accepts internal repeated separators");
  const auto signed_zero = ColorName::parse("#-00000");
  const std::array<Byte, 3> black{};
  require(signed_zero && std::get<CellColor>(*signed_zero).channels == black, "unsigned negative zero is a valid literal in the original parser");
  for (const auto *const text : {"", "red ", "#0x00ff", "#-00001", "#_fffff", "#fffff_", "#12345", "#1234567", "palette-red"}) {
    require(!ColorName::parse(text), "unknown or malformed written colors must stay invalid");
  }
}

void machineListRowsPlaceDiscLabelAndStack() {
  using Geometry = MachineChromeGeometry;
  const ChromeMetrics chrome;
  constexpr Rect area{.x = 8, .y = 40, .width = 224, .height = 64};
  const auto first = Geometry::listRow(area, chrome, 0, true);
  constexpr Rect bounds{.x = 8, .y = 40, .width = 224, .height = 32};
  constexpr Rect disc{.x = 16, .y = 52.5F, .width = 7, .height = 7};
  constexpr Rect stack{.x = 182, .y = 40, .width = 42, .height = 32};
  constexpr Rect label{.x = 31, .y = 40, .width = 143, .height = 32};
  require(first.bounds == bounds && first.disc == disc && first.stack == stack && first.label == label, "a machine row keeps its disc, label and agent stack apart");
  const auto second = Geometry::listRow(area, chrome, 1, false);
  constexpr Rect wide_label{.x = 31, .y = 72, .width = 193, .height = 32};
  require(second.bounds.y == 72 && second.stack.empty() && second.label == wide_label, "a row without agents gives the stack's room to its label");
  require(Geometry::listHeight(chrome, 3) == 96, "machine rows stack at their fixed height");
  constexpr float label_advance = 100;
  require(Geometry::listNaturalWidth(chrome, label_advance, false) == 131 && Geometry::listNaturalWidth(chrome, label_advance, true) == 181, "the natural width holds the whole label and, when shown, the stack");
}

void inlineMachineFactsKeepOriginalStateAndGeometry() {
  struct Case {
    MachinePhase phase;
    std::string_view glyph;
    PaletteRole ink;
  };

  constexpr std::array cases{
      Case{.phase = MachinePhase::connected, .glyph = "●", .ink = PaletteRole::green},
      Case{.phase = MachinePhase::connecting, .glyph = "◌", .ink = PaletteRole::overlay1},
      Case{.phase = MachinePhase::lost, .glyph = "✕", .ink = PaletteRole::peach},
      Case{.phase = MachinePhase::failed, .glyph = "✕", .ink = PaletteRole::red},
      Case{.phase = MachinePhase::stopped, .glyph = "○", .ink = PaletteRole::overlay0},
  };
  constexpr std::uint8_t cpu = 92;
  for (const auto &item : cases) {
    require(MachineFacts::glyph(item.phase, false) == item.glyph && MachineFacts::glyphInk(item.phase, false) == item.ink, "machine facts must retain original phase glyph and palette");
    require(MachineFacts::glyph(item.phase, true) == "●" && MachineFacts::glyphInk(item.phase, true) == PaletteRole::yellow, "attention must take precedence over every link phase");
    const auto expected_cpu = item.phase == MachinePhase::connected ? std::string_view{"92%"} : std::string_view{};
    require(MachineFacts::cpu(item.phase, cpu).view() == expected_cpu, "retained CPU must only paint for a connected machine");
  }

  require(MachineFacts::cpu(MachinePhase::connected, std::nullopt).view().empty(), "missing CPU must remain absent");
  require(MachineFacts::cpu(MachinePhase::connected, 0).view() == "0%", "a valid zero CPU sample must be visible");
  const ChromeMetrics chrome;
  constexpr MachineFacts::Widths parts{.glyph = 8, .label = 30, .cpu = 20};
  constexpr Rect area{.x = 10, .y = 20, .width = 200, .height = 26};
  constexpr Rect bounds{.x = 10, .y = 20, .width = 68, .height = 26};
  constexpr Rect label{.x = 23, .y = 20, .width = 30, .height = 26};
  constexpr Rect cpu_bounds{.x = 58, .y = 20, .width = 20, .height = 26};
  const auto geometry = MachineFacts::geometry(area, chrome, parts);
  require(geometry.bounds == bounds && geometry.label == label && geometry.cpu == cpu_bounds, "inline facts must use original unpadded label geometry and5px part gaps");
  auto missing = parts;
  missing.cpu = 0;
  constexpr float without_cpu = 43;
  require(MachineFacts::width(chrome, missing) == without_cpu && MachineFacts::geometry(area, chrome, missing).cpu.empty(), "absent CPU must reserve neither text nor trailing gap");
}

void machineControlInkAreasKeepOriginalInsets() {
  using Geometry = MachineChromeGeometry;
  const ChromeMetrics chrome;
  constexpr Rect bounds{.x = 10, .y = 30, .width = 50, .height = 20};
  constexpr Rect label{.x = 29, .y = 30, .width = 0, .height = 20};
  constexpr Rect disc{.x = 18, .y = 36.5F, .width = 7, .height = 7};
  constexpr Rect attention{.x = 48, .y = 37, .width = 6, .height = 6};
  constexpr float advance = 30;
  const auto control = Geometry::control(bounds, chrome, Geometry::Kind::switcher, advance, true);
  require(control.label == label && control.disc == disc && control.attention == attention, "machine ink areas retain asymmetric text insets, centered discs and trailing attention");
  constexpr Rect fold_bounds{.x = 10, .y = 30, .width = 40, .height = 20};
  constexpr Rect fold_label{.x = 20, .y = 30, .width = 20, .height = 20};
  const auto fold = Geometry::control(fold_bounds, chrome, Geometry::Kind::fold, fold_label.width, false);
  require(fold.label == fold_label && fold.disc.empty(), "the fold label centers independently of a machine disc");
  constexpr Rect fractional_bounds{.x = 8.25F, .y = 12.5F, .width = 8.5F, .height = 8.5F};
  constexpr float fractional_advance = 6.25F;
  constexpr float centered_origin = 9.25F;
  const auto fractional_fold = Geometry::control(fractional_bounds, chrome, Geometry::Kind::fold, fractional_advance, false);
  require(fractional_fold.label.x == centered_origin, "the fold keeps the original gfx layout's floored centering at fractional extents");
  constexpr std::array<std::array<float, 2>, 2> segments{{{100, 134}, {300, 200}}};
  for (const auto &segment : segments) {
    require(Geometry::preferredSegment(chrome, segment[0]) == segment[1], "the segment reserves its disc and padding before applying its cap");
  }
}

}

int main() {
  try {
    colorNamesKeepWrittenSemantics();
    machineListRowsPlaceDiscLabelAndStack();
    machineControlInkAreasKeepOriginalInsets();
    inlineMachineFactsKeepOriginalStateAndGeometry();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
