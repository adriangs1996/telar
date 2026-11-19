#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <string_view>

import telar.testing;
import telar.gui.foundation.core;
import telar.gui.features.machines;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::machines;

  void colorNamesKeepWrittenSemantics() {
    const auto role = ColorName::parse("PaNeL-Bg");

    check(role && std::get<PaletteRole>(*role) == PaletteRole::panel_bg, "machine colors normalize ASCII case and role separators");
    const auto inherited = ColorName::parse("DeFaUlT");

    check(inherited && std::get<CellColor>(*inherited).kind == CellColor::Kind::default_color, "an explicit default remains a default color, rather than an accent alias");
    const auto literal = ColorName::parse("#aBcDeF");
    const ds::Array<Byte, 3> expected{0xab, 0xcd, 0xef};

    check(literal && std::get<CellColor>(*literal).channels == expected, "hexadecimal machine ink preserves every byte");
    const auto separated = ColorName::parse("#ff__ff");
    const ds::Array<Byte, 3> cyan{0, 0xff, 0xff};

    check(separated && std::get<CellColor>(*separated).channels == cyan, "the original hexadecimal parser accepts internal repeated separators");
    const auto signed_zero = ColorName::parse("#-00000");
    const ds::Array<Byte, 3> black{};

    check(signed_zero && std::get<CellColor>(*signed_zero).channels == black, "unsigned negative zero is a valid literal in the original parser");
    for (const auto* const text : {"", "red ", "#0x00ff", "#-00001", "#_fffff", "#fffff_", "#12345", "#1234567", "palette-red"}) {
      check(!ColorName::parse(text), "unknown or malformed written colors must stay invalid");
    }
  }

  void machineListRowsPlaceAvatarTextAndStack() {
    using Geometry = MachineChromeGeometry;
    const ChromeMetrics chrome;
    constexpr Rect area{.x = 8, .y = 40, .width = 224, .height = 86};
    const auto first = Geometry::listRow(area, chrome, 0, true);
    constexpr Rect bounds{.x = 8, .y = 40, .width = 224, .height = 43};
    constexpr Rect avatar{.x = 16, .y = 50, .width = 24, .height = 24};
    constexpr Rect dot{.x = 35, .y = 69, .width = 7, .height = 7};
    constexpr Rect stack{.x = 182, .y = 40, .width = 42, .height = 43};
    constexpr Rect label{.x = 46, .y = 45, .width = 130, .height = 17};
    constexpr Rect status{.x = 46, .y = 62, .width = 130, .height = 16};

    check(first.bounds == bounds && first.avatar == avatar && first.dot == dot && first.stack == stack, "a machine row keeps its avatar, link dot and agent stack apart");
    check(first.label == label && first.status == status, "the status line sits under the label in the cards' text column");
    const auto second = Geometry::listRow(area, chrome, 1, false);
    constexpr Rect wide_label{.x = 46, .y = 88, .width = 178, .height = 17};

    check(second.bounds.y == bounds.y + bounds.height && second.stack.empty() && second.label == wide_label, "a row without agents gives the stack's room to its text");
    check(Geometry::listHeight(chrome, 3) == 3 * bounds.height, "machine rows stack at the height of their two lines");
    constexpr float text_advance = 100;
    constexpr float natural_width = 146;
    constexpr float natural_width_with_stack = 194;

    check(Geometry::listNaturalWidth(chrome, text_advance, false) == natural_width && Geometry::listNaturalWidth(chrome, text_advance, true) == natural_width_with_stack, "the natural width holds the whole text and, when shown, the stack");
    ChromeMetrics enlarged;

    enlarged.text_ratio = 2;
    check(Geometry::listRow(area, enlarged, 0, false).avatar.width == avatar.width * enlarged.text_ratio && Geometry::listRow(area, chrome, 0, false).avatar.width == avatar.width, "rows follow the chrome text, whatever the display ratio is");
  }

  void machineListStatusCountsActiveAgents() {
    using Geometry = MachineChromeGeometry;
    ds::Array<char, Geometry::list_status_capacity> storage{};
    constexpr std::size_t several = 12;

    check(Geometry::listStatus(false, 3, storage.viewMut()) == "Offline", "a machine whose link is down reads offline, whatever it last reported");
    check(Geometry::listStatus(true, 0, storage.viewMut()) == "No active agents" && Geometry::listStatus(true, 1, storage.viewMut()) == "1 active agent", "an idle machine and a single agent read in plain words");
    check(Geometry::listStatus(true, several, storage.viewMut()) == "12 active agents", "several agents read as their count");
    check(Geometry::listStatus(true, std::numeric_limits<std::size_t>::max(), storage.viewMut()) == "active agents", "a count that does not fit drops out instead of overrunning the storage");
  }

  void inlineMachineFactsKeepOriginalStateAndGeometry() {
    struct Case {
      MachinePhase phase;
      std::string_view glyph;
      PaletteRole ink;
    };

    constexpr ds::Array cases{
        Case{.phase = MachinePhase::connected, .glyph = "●", .ink = PaletteRole::green},
        Case{.phase = MachinePhase::connecting, .glyph = "◌", .ink = PaletteRole::overlay1},
        Case{.phase = MachinePhase::lost, .glyph = "✕", .ink = PaletteRole::peach},
        Case{.phase = MachinePhase::failed, .glyph = "✕", .ink = PaletteRole::red},
        Case{.phase = MachinePhase::stopped, .glyph = "○", .ink = PaletteRole::overlay0},
    };

    constexpr std::uint8_t cpu = 92;

    for (const auto& item : cases) {
      check(MachineFacts::glyph(item.phase, false) == item.glyph && MachineFacts::glyphInk(item.phase, false) == item.ink, "machine facts must retain original phase glyph and palette");
      check(MachineFacts::glyph(item.phase, true) == "●" && MachineFacts::glyphInk(item.phase, true) == PaletteRole::yellow, "attention must take precedence over every link phase");
      const auto expected_cpu = item.phase == MachinePhase::connected ? std::string_view{"92%"} : std::string_view{};

      check(MachineFacts::cpu(item.phase, cpu).view() == expected_cpu, "retained CPU must only paint for a connected machine");
    }

    check(MachineFacts::cpu(MachinePhase::connected, ds::none).view().empty(), "missing CPU must remain absent");
    check(MachineFacts::cpu(MachinePhase::connected, 0).view() == "0%", "a valid zero CPU sample must be visible");
    const ChromeMetrics chrome;
    constexpr MachineFacts::Widths parts{.glyph = 8, .label = 30, .cpu = 20};
    constexpr Rect area{.x = 10, .y = 20, .width = 200, .height = 26};
    constexpr Rect bounds{.x = 10, .y = 20, .width = 68, .height = 26};
    constexpr Rect label{.x = 23, .y = 20, .width = 30, .height = 26};
    constexpr Rect cpu_bounds{.x = 58, .y = 20, .width = 20, .height = 26};
    const auto geometry = MachineFacts::geometry(area, chrome, parts);

    check(geometry.bounds == bounds && geometry.label == label && geometry.cpu == cpu_bounds, "inline facts must use original unpadded label geometry and5px part gaps");
    auto missing = parts;

    missing.cpu = 0;
    constexpr float without_cpu = 43;

    check(MachineFacts::width(chrome, missing) == without_cpu && MachineFacts::geometry(area, chrome, missing).cpu.empty(), "absent CPU must reserve neither text nor trailing gap");
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

    check(control.label == label && control.disc == disc && control.attention == attention, "machine ink areas retain asymmetric text insets, centered discs and trailing attention");
    constexpr Rect fold_bounds{.x = 10, .y = 30, .width = 40, .height = 20};
    constexpr Rect fold_label{.x = 20, .y = 30, .width = 20, .height = 20};
    const auto fold = Geometry::control(fold_bounds, chrome, Geometry::Kind::fold, fold_label.width, false);

    check(fold.label == fold_label && fold.disc.empty(), "the fold label centers independently of a machine disc");
    constexpr Rect fractional_bounds{.x = 8.25F, .y = 12.5F, .width = 8.5F, .height = 8.5F};
    constexpr float fractional_advance = 6.25F;
    constexpr float centered_origin = 9.25F;
    const auto fractional_fold = Geometry::control(fractional_bounds, chrome, Geometry::Kind::fold, fractional_advance, false);

    check(fractional_fold.label.x == centered_origin, "the fold keeps the original gfx layout's floored centering at fractional extents");
    constexpr ds::Array<ds::Array<float, 2>, 2> segments{{{100, 134}, {300, 200}}};

    for (const auto& segment : segments) {
      check(Geometry::preferredSegment(chrome, segment[0]) == segment[1], "the segment reserves its disc and padding before applying its cap");
    }
  }

  const telar::testing::Case case_color_names_keep_written_semantics{"machine_chrome.color_names_keep_written_semantics", colorNamesKeepWrittenSemantics};
  const telar::testing::Case case_machine_list_rows_place_avatar_text_and_stack{"machine_chrome.machine_list_rows_place_avatar_text_and_stack", machineListRowsPlaceAvatarTextAndStack};
  const telar::testing::Case case_machine_list_status_counts_active_agents{"machine_chrome.machine_list_status_counts_active_agents", machineListStatusCountsActiveAgents};
  const telar::testing::Case case_machine_control_ink_areas_keep_original_insets{"machine_chrome.machine_control_ink_areas_keep_original_insets", machineControlInkAreasKeepOriginalInsets};
  const telar::testing::Case case_inline_machine_facts_keep_original_state_and_geometry{"machine_chrome.inline_machine_facts_keep_original_state_and_geometry", inlineMachineFactsKeepOriginalStateAndGeometry};

}
