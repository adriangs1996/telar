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
import telar.gui.foundation.actions;
import telar.wire.monitor;
import telar.gui.foundation.text;
import telar.base.ds;

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

      check(query.mode == PaletteMode::all && query.text == text, "plain or empty input must search every kind of row");
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

  void paletteScoresPreferWordStartsAndRuns() {
    const auto score = [](std::string_view label, std::string_view query) {
      return PaletteScore::of(label, query).valueOr(0);
    };

    check(PaletteScore::of("Split right", "") == 1U, "an empty query must keep every row with the same score");
    check(!PaletteScore::of("Split right", "rs").hasValue(), "a query out of order must not match");
    check(score("SPLIT right", "split") == score("Split right", "split"), "matching must ignore ASCII case");
    check(score("telar  lifetime-speed", "ter") > score("Enter copy mode", "ter"), "a word start must outrank a match inside a word");
    check(score("tab Claude Code", "code") > score("Enter copy mode", "code"), "a whole word must outrank scattered letters");
    check(score("Close tab", "ct") > score("Rename context", "ct"), "word starts must outrank letters inside words");
    check(score("Split right", "split") > score("Split down", "sd"), "a contiguous run must outrank a gapped match");
    check(score("xxab", "ab") < score("ab", "ab"), "a match at a word start must outrank one inside a word");
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
    constexpr float ordinary_height = 426;
    constexpr float ordinary_top = 110;
    const auto geometry = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, chrome, {});

    check(geometry.bounds.width == PaletteGeometry::maximum_width && geometry.bounds.height == ordinary_height && geometry.bounds.y == ordinary_top, "ordinary palette bounds must follow the native reference");
    check(geometry.heading.height == 0, "the unified palette must not reserve a nested heading");

    for (const auto extent : {0.0F, 1.0F, 2.0F, PaletteGeometry::margin}) {
      const auto tiny = PaletteGeometry::measure({.width = extent, .height = extent}, chrome, {});

      check(tiny.bounds.width >= 0 && tiny.bounds.height >= 0 && tiny.results.height >= 0 && tiny.footer.height >= 0, "small windows must never create negative regions");
      const telar::ds::Array bands{tiny.heading, tiny.search, tiny.results, tiny.footer};
      const auto tolerance = std::numeric_limits<float>::epsilon() * std::max(1.0F, tiny.bounds.height) * static_cast<float>(bands.size());
      auto bottom = tiny.bounds.y;

      for (const auto band : bands) {
        check(std::abs(band.y - bottom) <= tolerance, "palette bands must follow each other without overlap");
        bottom = band.bottom();
      }

      check(std::abs(bottom - tiny.bounds.bottom()) <= tolerance, "palette bands must cover the panel within floating-point rounding");
    }
  }

  // A larger chrome font widens the palette and its rows with the text, up to the window's margin.
  void thePaletteGrowsWithItsText() {
    constexpr float growth = 1.5F;
    const ChromeMetrics design;
    ChromeMetrics grown;
    grown.text_ratio = growth;
    constexpr float viewport_width = 1600;
    constexpr float viewport_height = 1000;
    const auto reference = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, design, {});
    const auto geometry = PaletteGeometry::measure({.width = viewport_width, .height = viewport_height}, grown, {});

    check(geometry.bounds.width == PaletteGeometry::maximum_width * growth, "the palette's width must grow with its text");
    check(geometry.row_height >= reference.row_height && geometry.search.height >= reference.search.height, "the palette's rows must not shrink as its text grows");

    constexpr float narrow_width = 700;
    const auto narrow = PaletteGeometry::measure({.width = narrow_width, .height = viewport_height}, grown, {});

    check(narrow.bounds.x >= PaletteGeometry::margin && narrow.bounds.right() <= narrow_width - PaletteGeometry::margin, "a grown palette must keep the window's margin");
  }

  void theVisibleWindowContainsItsSelectionAndGroupHeading() {
    const ChromeMetrics chrome;
    constexpr float viewport_width = 900;
    constexpr float viewport_height = 300;
    constexpr std::size_t row_count = 24;
    telar::ds::Array<PaletteRowKind, row_count> kinds{};

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
  const telar::testing::Case case_palette_scores_prefer_word_starts_and_runs{"palette.palette_scores_prefer_word_starts_and_runs", paletteScoresPreferWordStartsAndRuns};
  const telar::testing::Case case_labels_retain_only_complete_utf8_at_the_capacity_boundary{"palette.labels_retain_only_complete_utf8_at_the_capacity_boundary", labelsRetainOnlyCompleteUtf8AtTheCapacityBoundary};
  const telar::testing::Case case_palette_regions_fit_small_and_ordinary_windows{"palette.palette_regions_fit_small_and_ordinary_windows", paletteRegionsFitSmallAndOrdinaryWindows};

  // Every monitor operation the CLI offers has its binding action and its palette entry, with the
  // label the registry names.
  void monitorOperationsReachThePalette() {
    for (const auto& operation : telar::monitor_operations) {
      const auto action = builtinBindingAction(operation.binding);

      check(action.hasValue(), operation.binding);

      const auto* const entry = std::ranges::find(palette_actions, action->kind, &PaletteAction::action);

      check(entry != palette_actions.end() && entry->label == operation.label, operation.label);
    }
  }

  const telar::testing::Case case_the_palette_grows_with_its_text{"palette.the_palette_grows_with_its_text", thePaletteGrowsWithItsText};
  const telar::testing::Case case_the_visible_window_contains_its_selection_and_group_heading{"palette.the_visible_window_contains_its_selection_and_group_heading", theVisibleWindowContainsItsSelectionAndGroupHeading};
  const telar::testing::Case case_monitor_operations{"palette.monitor_operations_reach_the_palette", monitorOperationsReachThePalette};

}
