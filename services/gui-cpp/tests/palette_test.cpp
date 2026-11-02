#include "core/metrics.hpp"
#include "palette/navigation_label.hpp"
#include "palette/query.hpp"
#include "palette/ranked_matches.hpp"
#include "presentation/palette_geometry.hpp"
#include "presentation/palette_row_window.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void queryModesPreserveTheActualSearch() {
  for (const auto mode : {PaletteMode::navigate, PaletteMode::actions, PaletteMode::machines, PaletteMode::suggest}) {
    std::string text{static_cast<char>(mode)};
    text.append("name @ second");
    const auto query = PaletteQuery::parse(text);
    require(query.mode == mode && query.text == "name @ second", "only one leading recognized prefix must be removed");
  }

  for (const auto text : {std::string_view{}, std::string_view{"context"}, std::string_view{" @context"}, std::string_view{"éclair"}}) {
    const auto query = PaletteQuery::parse(text);
    require(query.mode == PaletteMode::navigate && query.text == text, "plain or empty input must remain a navigation query");
  }
}

void fuzzyRankingKeepsStableTiesAndBoundedStorage() {
  RankedMatches<std::uint16_t, 4> matches;
  matches.add(1, "a-b", "AB");
  matches.add(2, "xxab", "AB");
  matches.add(3, "ab", "AB");
  matches.add(4, "unrelated", "AB");
  const auto rows = matches.rows();
  require(rows.size() == 3 && rows[0].target == 3 && rows[1].target == 1 && rows[2].target == 2, "fuzzy subsequences must rank by score and preserve input order among ties");

  matches.add(4, "aaaab", "ab");
  matches.add(1, "zzab", "ab");
  require(matches.rows().size() == 4 && matches.rows().back().target == 1, "a full result set must retain the highest ranked candidates");
  matches.clear();
  matches.add(2, "second", "");
  matches.add(1, "first", "");
  require(matches.rows().size() == 2 && matches.rows().front().target == 2, "an empty query must preserve canonical source order");
}

void labelsRetainOnlyCompleteUtf8AtTheCapacityBoundary() {
  NavigationLabel label;
  const std::string leading(NavigationLabel::capacity - 1, 'a');
  label.append(leading);
  label.append("éclair");
  label.appendDetail("branch");
  require(label.view() == leading, "a full label must remove the incomplete final scalar without reusing its bytes");

  NavigationLabel tab;
  tab.append(NavigationLabel::tab_prefix);
  tab.append("shell");
  require(tab.view() == "tab shell", "a tab must search its canonical name with the original tab prefix");

  NavigationLabel agent;
  agent.append("provider");
  agent.appendDetail("");
  agent.appendDetail("session");
  agent.appendDetail("context");
  require(agent.view() == "provider  session  context", "empty details must not add separators");
}

void paletteRegionsFitSmallAndOrdinaryWindows() {
  const ChromeMetrics chrome;
  constexpr float viewport_width = 1600;
  constexpr float viewport_height = 1000;
  constexpr float ordinary_height = 464;
  constexpr float ordinary_top = 110;
  const auto geometry = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, chrome, {});
  require(geometry.bounds.width == PaletteGeometry::maximum_width && geometry.bounds.height == ordinary_height && geometry.bounds.y == ordinary_top, "ordinary palette bounds must follow the native reference");
  require(geometry.heading.height == 0 && geometry.tabs.height == PaletteGeometry::tabs_minimum, "the unified palette must reserve tabs but no nested heading");

  for (const auto extent : {0.0F, 1.0F, 2.0F, PaletteGeometry::margin}) {
    const auto tiny = PaletteGeometry::measure({.width = extent, .height = extent}, chrome, {});
    require(tiny.bounds.width >= 0 && tiny.bounds.height >= 0 && tiny.results.height >= 0 && tiny.footer.height >= 0, "small windows must never create negative regions");
    const std::array bands{tiny.heading, tiny.search, tiny.tabs, tiny.results, tiny.footer};
    const auto tolerance = std::numeric_limits<float>::epsilon() * std::max(1.0F, tiny.bounds.height) * static_cast<float>(bands.size());
    auto bottom = tiny.bounds.y;
    for (const auto band : bands) {
      require(std::abs(band.y - bottom) <= tolerance, "palette bands must follow each other without overlap");
      bottom = band.bottom();
    }

    require(std::abs(bottom - tiny.bounds.bottom()) <= tolerance, "palette bands must cover the panel within floating-point rounding");
  }
}

void theVisibleWindowContainsItsSelectionAndGroupHeading() {
  const ChromeMetrics chrome;
  constexpr float viewport_width = 900;
  constexpr float viewport_height = 300;
  constexpr std::size_t row_count = 24;
  std::array<PaletteRowKind, row_count> kinds{};
  kinds.fill(PaletteRowKind::agent);
  const auto geometry = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, chrome, {});
  for (std::size_t selected = 0; selected < kinds.size(); ++selected) {
    const auto visible = PaletteRowWindow::measure(kinds, selected, geometry, chrome, true);
    require(visible.count > 0 && visible.count <= PaletteRowWindow::capacity, "a sufficiently tall list must paint a bounded set of rows");
    require(visible.first <= selected && visible.first + visible.count > selected, "the visible window must always contain the selected result");
    require(visible.rows.front().group.height == geometry.group_height, "a scrolled group must retain its heading");
    for (std::size_t index = 0; index < visible.count; ++index) {
      require(visible.rows[index].bounds.bottom() <= geometry.results.bottom(), "a visible result must fit within the list band");
    }
  }
}

}

int main() {
  try {
    queryModesPreserveTheActualSearch();
    fuzzyRankingKeepsStableTiesAndBoundedStorage();
    labelsRetainOnlyCompleteUtf8AtTheCapacityBoundary();
    paletteRegionsFitSmallAndOrdinaryWindows();
    theVisibleWindowContainsItsSelectionAndGroupHeading();
    std::cout << "Palette matching, labels and geometry passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
