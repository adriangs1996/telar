#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.base.history;
import telar.gui.foundation.core;
import telar.gui.foundation.forms;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  // The bytes of `command` the ranges mark, in order.
  std::string markedText(std::string_view command, const HistoryMatchRanges& ranges) {
    std::string result;

    for (const auto range : ranges.view()) {
      result.append(command.substr(range.offset, range.length));
    }

    return result;
  }

  // What the runtime's matcher covers, as the runtime reads it.
  std::string runtimeMarked(std::string_view command, std::string_view query) {
    const auto arena = std::make_unique<telar::runtime::HistoryMatchArena>();
    const telar::runtime::HistoryPattern pattern{query};
    telar::runtime::HistoryMatchRanges ranges;
    std::string result;

    if (telar::runtime::historyMatch(pattern, command, *arena, &ranges)) {
      for (const auto range : ranges.view()) {
        result.append(command.substr(range.begin, range.end - range.begin));
      }
    }

    return result;
  }

  // The highlight marks what the runtime's matcher matched, beyond ASCII too, with its extended
  // syntax and smart case.
  void rangesAreWhatTheRuntimeMatches() {
    struct Example {
      std::string_view command;
      std::string_view query;
      std::string_view marked;
    };

    constexpr telar::ds::Array examples{
        Example{.command = "git commit -m 'ÉCOLE'", .query = "éc", .marked = "ÉC"},
        Example{.command = "echo ПРИВЕТ мир", .query = "привет", .marked = "ПРИВЕТ"},
        Example{.command = "grep ΑΘΗΝΑ", .query = "αθηνα", .marked = "ΑΘΗΝΑ"},
        Example{.command = "make build", .query = "mb", .marked = "mb"},
        // A term that must not match marks nothing; the others mark what they matched.
        Example{.command = "git push origin", .query = "git !wip", .marked = "git"},
        // A capital makes the term match case for case.
        Example{.command = "make build", .query = "MB", .marked = ""},
    };

    for (const auto& example : examples) {
      const auto ranges = HistoryMatchRanges::find(example.command, example.query);

      check(markedText(example.command, ranges) == example.marked, "the highlight marks what the query matched");
      check(markedText(example.command, ranges) == runtimeMarked(example.command, example.query), "the highlight is what the runtime's matcher covers");
    }
  }

  // A query that is not all there marks nothing, as the runtime would not list the command.
  void rangesOfAMissingQueryAreEmpty() {
    constexpr std::string_view command = "cargo test";

    check(HistoryMatchRanges::find(command, "cx").view().empty(), "a partial match marks nothing");
    check(runtimeMarked(command, "cx").empty(), "and the runtime matches nothing");
    check(HistoryMatchRanges::find(command, "").view().empty(), "an empty query marks nothing");
  }

  // Adjacent characters make one run; a character of several bytes is one run of its bytes.
  void rangesJoinAdjacentCharacters() {
    constexpr std::string_view command = "über alles";
    const auto ranges = HistoryMatchRanges::find(command, "übe");

    check(ranges.view().size() == 1 && ranges.view().front().offset == 0 && ranges.view().front().length == std::string_view{"übe"}.size(), "a contiguous match is one run");
    check(ranges.covers(1, 1) && !ranges.covers(std::string_view{"übe"}.size(), 1), "a run covers the bytes it holds and no others");
  }

  // A byte that starts no character matches only itself and leaves the rest of the text whole.
  void rangesKeepInvalidBytesApart() {
    constexpr std::string_view command = "a\xff"
                                         "b";
    const auto ranges = HistoryMatchRanges::find(command, "ab");

    check(ranges.view().size() == 2 && ranges.view()[1].offset == 2, "an invalid byte between matches splits their runs");
  }

  // The highlight paints the clusters a range covers, on each line at its place in the command.
  void highlightsPaintTheCoveredClustersOfEachLine() {
    constexpr std::string_view command = "á中B\nsecond";
    const auto ranges = HistoryMatchRanges::find(command, "中bs");
    HistoryMatchHighlight highlight{ranges};
    constexpr float cell_width = 8;
    constexpr Rect first{.x = 10, .y = 20, .width = 100, .height = 20};
    constexpr Rect second{.x = 10, .y = 40, .width = 100, .height = 20};
    telar::ds::Array<Rect, 3> matches{};
    std::size_t count = 0;
    auto record = [&](Rect area, std::string_view) {
      matches.atCheckedMut(count++) = area;
    };

    const auto line_end = command.find('\n');

    highlight.paint(command.substr(0, line_end), 0, first, cell_width, record);
    highlight.paint(command.substr(line_end + 1), line_end + 1, second, cell_width, record);
    check(count == matches.size() && highlight.matched() == std::string_view{"中BS"}.size(), "every matched cluster of both lines is painted");
    check(matches.front().width == 2 * cell_width && matches.front().x == first.x + cell_width && matches.back().y == second.y, "wide clusters and the next line keep their cell rectangles");

    const auto wide = HistoryMatchRanges::find("中", "中");
    HistoryMatchHighlight clipped{wide};
    constexpr Rect narrow{.width = cell_width, .height = 20};

    clipped.paint("中", 0, narrow, cell_width, record);
    check(clipped.matched() == 0 && count == matches.size(), "a cluster cut by the edge is not painted");
  }

  const telar::testing::Case case_ranges_are_what_the_runtime_matches{"history_match.ranges_are_what_the_runtime_matches", rangesAreWhatTheRuntimeMatches};
  const telar::testing::Case case_ranges_of_a_missing_query_are_empty{"history_match.ranges_of_a_missing_query_are_empty", rangesOfAMissingQueryAreEmpty};
  const telar::testing::Case case_ranges_join_adjacent_characters{"history_match.ranges_join_adjacent_characters", rangesJoinAdjacentCharacters};
  const telar::testing::Case case_ranges_keep_invalid_bytes_apart{"history_match.ranges_keep_invalid_bytes_apart", rangesKeepInvalidBytesApart};
  const telar::testing::Case case_highlights_paint_the_covered_clusters_of_each_line{"history_match.highlights_paint_the_covered_clusters_of_each_line", highlightsPaintTheCoveredClustersOfEachLine};

}
