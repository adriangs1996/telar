#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.features.palette;
import telar.gui.foundation.text;

namespace {

  using telar::testing::check;
  using namespace telar::gui;
  using namespace telar::gui::features::palette;

  void queryModesPreserveTheActualSearch() {
    for (const auto mode : {PaletteMode::navigate, PaletteMode::actions, PaletteMode::machines, PaletteMode::suggest}) {
      std::string text{static_cast<char>(mode)};

      text.append("name @ second");
      const auto query = PaletteQuery::parse(text);

      check(query.mode == mode && query.text == "name @ second", "only one leading recognized prefix must be removed");
    }

    for (const auto text : {std::string_view{}, std::string_view{"context"}, std::string_view{" @context"}, std::string_view{"éclair"}}) {
      const auto query = PaletteQuery::parse(text);

      check(query.mode == PaletteMode::navigate && query.text == text, "plain or empty input must remain a navigation query");
    }
  }

  void fuzzyRankingKeepsStableTiesAndBoundedStorage() {
    RankedMatches<std::uint16_t, 4> matches;

    matches.add(1, "a-b", "AB");
    matches.add(2, "xxab", "AB");
    matches.add(3, "ab", "AB");
    matches.add(4, "unrelated", "AB");
    const auto rows = matches.rows();

    check(rows.size() == 3 && rows[0].target == 3 && rows[1].target == 1 && rows[2].target == 2, "fuzzy subsequences must rank by score and preserve input order among ties");

    matches.add(4, "aaaab", "ab");
    matches.add(1, "zzab", "ab");
    check(matches.rows().size() == 4 && matches.rows().back().target == 1, "a full result set must retain the highest ranked candidates");
    matches.clear();
    matches.add(2, "second", "");
    matches.add(1, "first", "");
    check(matches.rows().size() == 2 && matches.rows().front().target == 2, "an empty query must preserve canonical source order");
  }

  void labelsRetainOnlyCompleteUtf8AtTheCapacityBoundary() {
    NavigationLabel label;
    const std::string leading(NavigationLabel::capacity - 1, 'a');

    label.append(leading);
    label.append("éclair");
    label.appendDetail("branch");
    check(label.view() == leading, "a full label must remove the incomplete final scalar without reusing its bytes");

    NavigationLabel tab;

    tab.append(NavigationLabel::tab_prefix);
    tab.append("shell");
    check(tab.view() == "tab shell", "a tab must search its canonical name with the original tab prefix");

    NavigationLabel agent;

    agent.append("provider");
    agent.appendDetail("");
    agent.appendDetail("session");
    agent.appendDetail("context");
    check(agent.view() == "provider  session  context", "empty details must not add separators");
  }

  void paletteRegionsFitSmallAndOrdinaryWindows() {
    const ChromeMetrics chrome;
    constexpr float viewport_width = 1600;
    constexpr float viewport_height = 1000;
    constexpr float ordinary_height = 464;
    constexpr float ordinary_top = 110;
    const auto geometry = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, chrome, {});

    check(geometry.bounds.width == PaletteGeometry::maximum_width && geometry.bounds.height == ordinary_height && geometry.bounds.y == ordinary_top, "ordinary palette bounds must follow the native reference");
    check(geometry.heading.height == 0 && geometry.tabs.height == PaletteGeometry::tabs_minimum, "the unified palette must reserve tabs but no nested heading");

    for (const auto extent : {0.0F, 1.0F, 2.0F, PaletteGeometry::margin}) {
      const auto tiny = PaletteGeometry::measure({.width = extent, .height = extent}, chrome, {});

      check(tiny.bounds.width >= 0 && tiny.bounds.height >= 0 && tiny.results.height >= 0 && tiny.footer.height >= 0, "small windows must never create negative regions");
      const std::array bands{tiny.heading, tiny.search, tiny.tabs, tiny.results, tiny.footer};
      const auto tolerance = std::numeric_limits<float>::epsilon() * std::max(1.0F, tiny.bounds.height) * static_cast<float>(bands.size());
      auto bottom = tiny.bounds.y;

      for (const auto band : bands) {
        check(std::abs(band.y - bottom) <= tolerance, "palette bands must follow each other without overlap");
        bottom = band.bottom();
      }

      check(std::abs(bottom - tiny.bounds.bottom()) <= tolerance, "palette bands must cover the panel within floating-point rounding");
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

      check(visible.count > 0 && visible.count <= PaletteRowWindow::capacity, "a sufficiently tall list must paint a bounded set of rows");
      check(visible.first <= selected && visible.first + visible.count > selected, "the visible window must always contain the selected result");
      check(visible.rows.front().group.height == geometry.group_height, "a scrolled group must retain its heading");
      for (std::size_t index = 0; index < visible.count; ++index) {
        check(visible.rows[index].bounds.bottom() <= geometry.results.bottom(), "a visible result must fit within the list band");
      }
    }
  }

  const telar::testing::Case case_query_modes_preserve_the_actual_search{"palette.query_modes_preserve_the_actual_search", queryModesPreserveTheActualSearch};
  const telar::testing::Case case_fuzzy_ranking_keeps_stable_ties_and_bounded_storage{"palette.fuzzy_ranking_keeps_stable_ties_and_bounded_storage", fuzzyRankingKeepsStableTiesAndBoundedStorage};
  const telar::testing::Case case_labels_retain_only_complete_utf8_at_the_capacity_boundary{"palette.labels_retain_only_complete_utf8_at_the_capacity_boundary", labelsRetainOnlyCompleteUtf8AtTheCapacityBoundary};
  const telar::testing::Case case_palette_regions_fit_small_and_ordinary_windows{"palette.palette_regions_fit_small_and_ordinary_windows", paletteRegionsFitSmallAndOrdinaryWindows};
  const telar::testing::Case case_the_visible_window_contains_its_selection_and_group_heading{"palette.the_visible_window_contains_its_selection_and_group_heading", theVisibleWindowContainsItsSelectionAndGroupHeading};

}
