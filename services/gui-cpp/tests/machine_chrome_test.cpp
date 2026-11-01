#include "assertions.hpp"
#include "core/color_name.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "machines/limits.hpp"
#include "presentation/machine_chrome_geometry.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <exception>
#include <iostream>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

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

void machineRowsReserveTheirFoldAndKeepSlotOrder() {
  using Geometry = MachineChromeGeometry;
  constexpr float more_advance = 24;
  const ChromeMetrics chrome;
  constexpr std::array advances{30.0F, 80.0F};

  struct Case {
    Rect bounds{};
    std::size_t count = 0;
    std::size_t hidden = 0;
    Rect first{};
    Rect second{};
    Rect fold{};
  };

  constexpr std::array cases{
      Case{.bounds = {.width = 300, .height = 17}, .count = 2, .hidden = 0, .first = {.width = 57, .height = 17}, .second = {.x = 61, .width = 107, .height = 17}},
      Case{.bounds = {.width = 150, .height = 17}, .count = 1, .hidden = 1, .first = {.width = 57, .height = 17}, .fold = {.x = 61, .width = 40, .height = 17}},
      Case{.bounds = {.width = 20, .height = 17}, .count = 0, .hidden = 2, .fold = {.width = 20, .height = 17}},
  };
  for (const auto &expected : cases) {
    const auto row = Geometry::switcher(expected.bounds, chrome, advances, more_advance);
    require(row.count == expected.count && row.hidden == expected.hidden && row.controls[0] == expected.first && row.controls[1] == expected.second && row.fold == expected.fold, "machine rows retain measured source order, bounded fold reservation and exact geometry");
  }

  require(Geometry::switcher(cases.front().bounds, chrome, std::span{advances}.first(1), more_advance).count == 0, "single-machine windows must keep their original chrome");
  std::array<float, MachineLimits::window_slots + 1> too_many{};
  bool rejected = false;
  try {
    static_cast<void>(Geometry::switcher(cases.front().bounds, chrome, too_many, more_advance));
  } catch (const std::length_error &) {
    rejected = true;
  }

  require(rejected, "machine chrome cannot exceed the shared bounded machine capacity");
}

void switcherPreferredWidthFitsEveryControl() {
  using Geometry = MachineChromeGeometry;
  const ChromeMetrics chrome;
  constexpr std::array<float, 2> advances{30, 300};
  constexpr float more_advance = 20;
  constexpr float expected_width = 217;
  const auto width = Geometry::preferredSwitcher(chrome, advances, more_advance);
  require(width == expected_width, "switcher intrinsic width must reserve the original control caps, gaps and fold budget");
  const Rect bounds{.width = width, .height = 26};
  const auto complete = Geometry::switcher(bounds, chrome, advances, more_advance);
  require(complete.count == advances.size() && complete.hidden == 0, "the preferred width must show every machine");
  auto narrow = bounds;
  --narrow.width;
  require(Geometry::switcher(narrow, chrome, advances, more_advance).hidden == 1, "the preferred width must use the existing switcher fitting boundary");
  require(Geometry::preferredSwitcher(chrome, {}, more_advance) == 0 && Geometry::preferredSwitcher(chrome, std::span{advances}.first(1), more_advance) == 0, "a switcher with at most one machine must remain absent");
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
    machineRowsReserveTheirFoldAndKeepSlotOrder();
    machineControlInkAreasKeepOriginalInsets();
    switcherPreferredWidthFitsEveryControl();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
