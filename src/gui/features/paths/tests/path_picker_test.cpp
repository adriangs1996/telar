#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.paths;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::paths;

  void pagesKeepOnlyTheCurrentRootAndRequest() {
    constexpr std::uint32_t partial_scanned = 12;
    constexpr std::uint32_t completed_scanned = 23;
    features::paths::State state;

    features::paths::open(state, 1, "/work", {});
    check(features::paths::page(state).root() == "/work" && features::paths::page(state).anchor() == "/work" && features::paths::search(state, {}, 1).refresh, "opening must retain the pane directory and request an index rebuild");
    features::paths::wait(state, 1);
    features::paths::wait(state, 2);
    const std::array highlights{std::uint16_t{1}};
    std::string path = "src/main.cpp";
    const std::array matches{PathMatch{.path = path, .positions = highlights}};

    check(!features::paths::receive(state, {.request_id = 1, .root = "/work", .matches = matches}), "a late page must not replace the latest query");
    check(!features::paths::receive(state, {.request_id = 2, .root = "/other", .matches = matches}), "a current request must still match the current root");
    check(features::paths::receive(state, {.request_id = 2, .root = "/work", .scanned = partial_scanned, .complete = false, .matches = matches}), "an incomplete page must be publishable while the index grows");
    path.assign("destroyed");
    check(features::paths::page(state).path(features::paths::page(state).matches().front()) == "src/main.cpp" && features::paths::page(state).matches().front().highlights().front() == 1, "retained pages must own path bytes and highlighting positions");
    check(features::paths::page(state).pendingRequest() == 2 && !features::paths::page(state).complete() && !features::paths::search(state, {}, 1).refresh, "partial results must retain the current request without another rebuild");
    check(features::paths::receive(state, {.request_id = 2, .root = "/work", .scanned = completed_scanned, .complete = true, .truncated = true}), "the completed page must retire the current correlation");
    check(features::paths::page(state).matches().empty() && features::paths::page(state).pendingRequest() == 0 && features::paths::page(state).scanned() == completed_scanned && features::paths::page(state).truncated(), "a final empty result must replace the preceding page and its metadata");
    check(features::paths::fail(state, {.request_id = 1, .message = "old failure"}).hasValue() && features::paths::page(state).phase() == PathPickerPhase::ready, "tracked obsolete failures must be consumed without replacing the displayed state");
    features::paths::wait(state, 3);
    features::paths::close(state);
    check(!features::paths::receive(state, {.request_id = 3, .root = "/work", .complete = true}), "closing must reject late pages");
    check(features::paths::fail(state, {.request_id = 3, .message = "late failure"}).hasValue() && features::paths::page(state).phase() == PathPickerPhase::idle, "closing must still recognize late failures without reopening the picker");
  }

  void failuresKeepOnlyBoundedUtf8AndTrackedIdentities() {
    features::paths::State state;

    features::paths::open(state, 1, "/work", {});
    for (std::size_t index = 1; index <= PathPickerLimits::tracked_requests + 1; ++index) {
      features::paths::wait(state, index);
    }

    check(!features::paths::fail(state, {.request_id = 1, .message = "untracked"}).hasValue(), "an evicted request must not claim another failure");
    const std::string leading(PathPickerLimits::error_bytes - 1, 'x');
    const auto message = leading + "🧵";

    check(features::paths::fail(state, {.request_id = PathPickerLimits::tracked_requests + 1, .message = message}).hasValue(), "the current request must own its failure");
    check(features::paths::page(state).phase() == PathPickerPhase::failed && features::paths::page(state).error() == leading && features::paths::page(state).pendingRequest() == 0, "failure text must stop at a complete UTF-8 scalar and retire the pending request");
  }

  void insertionsPreserveTheSelectedShellWord() {
    const auto quoted = PathInsertion::quote("a b'c");
    const auto option = PathInsertion::quote("-a b");
    const auto plain = PathInsertion::quote("file.cpp");

    check(quoted && quoted->view() == "'a b'\\''c'", "shell quoting must preserve spaces and embedded single quotes");
    check(option && option->view() == "./'-a b'", "option-like names must remain paths after quoting");
    check(plain && plain->view() == "file.cpp", "plain paths must not acquire unnecessary quotes");
    check(!PathInsertion::relativeTo("/work", "/worktree/file"), "a path sharing a name prefix must not become relative");
    check(PathInsertion::relativeTo("/", "/file") == ds::Option<std::string_view>{"file"}, "the filesystem root must not require a second separator");
    features::paths::State state;
    const std::array directories{PathMatch{.path = "sub/", .kind = PathKind::directory}};

    features::paths::open(state, 1, "/work", {});
    features::paths::wait(state, 1);
    check(features::paths::receive(state, {.request_id = 1, .root = "/work", .complete = true, .matches = directories}) && features::paths::descend(state, 0), "the insertion fixture must browse into its directory");
    features::paths::wait(state, 2);
    const std::array matches{PathMatch{.path = "a b.txt"}};

    check(features::paths::receive(state, {.request_id = 2, .root = "/work/sub", .complete = true, .matches = matches}), "the insertion fixture must adopt its result");
    const auto relative = features::paths::insertion(state, {});
    const auto absolute = features::paths::insertion(state, {.absolute = true});
    const auto bracketed = features::paths::insertion(state, {.bracketed = true});

    check(relative && relative->view() == "'sub/a b.txt'", "nested paths must remain relative to the opening directory");
    check(absolute && absolute->view() == "'/work/sub/a b.txt'", "alternate submission must preserve the absolute path");
    check(bracketed && bracketed->view() == "\x1b[200~'sub/a b.txt'\x1b[201~", "bracketed paste must be encoded as one complete delivery");
  }

  void placementFollowsTheCursorAndTheAvailableRows() {
    const CellRectangle host{.width = 100, .height = 30};
    constexpr CellRectangle expected_below{.x = 8, .y = 3, .width = 72, .height = 14};
    constexpr CellRectangle expected_above{.x = 28, .y = 14, .width = 72, .height = 14};
    constexpr CellRectangle expected_absent{.x = 14, .y = 8, .width = 72, .height = 5};
    const auto below = PathPickerPlacement::forPage(host, CellPosition{.x = 10, .y = 2}, PathPickerLimits::results);

    check(!below.flipped && below.area == expected_below, "a picker with room must open below the cursor");
    const auto above = PathPickerPlacement::forPage(host, CellPosition{.x = 90, .y = 28}, PathPickerLimits::results);

    check(above.flipped && above.area == expected_above, "a low cursor must keep the field beside it and the matches above");
    const auto absent = PathPickerPlacement::forPage(host, {}, 0);

    check(!absent.flipped && absent.area == expected_absent, "a missing cursor must use the original centered fallback");
  }

  void pathLabelsPreserveTheNameAndHighlightedScalars() {
    PathLabel label;
    constexpr std::uint16_t wide_columns = 80;
    constexpr std::uint16_t compact_columns = 10;
    const std::array positions{std::uint16_t{5}};

    label.layout("src/main.cpp", positions, wide_columns);
    check(label.runs().size() == 4 && label.runs()[0].text == "src/" && label.runs()[0].tone == PathLabelTone::directory && label.runs()[2].text == "a" && label.runs()[2].tone == PathLabelTone::match, "path labels must separate directory, name and highlighted characters");
    label.layout("deep/directory/file.cpp", {}, compact_columns);
    check(label.runs().size() == 3 && label.runs()[0].text == "d" && label.runs()[1].tone == PathLabelTone::ellipsis && label.runs()[2].text == "file.cpp", "truncation must remove the directory middle before the filename");
  }

  void geometryKeepsTheQueryBesideTheCursor() {
    const CellRectangle host{.width = 100, .height = 30};
    const auto placement = PathPickerPlacement::forPage(host, CellPosition{.x = 10, .y = 2}, PathPickerLimits::results);
    constexpr std::size_t selection = 13;
    constexpr PathPickerFieldColumns columns{.root = 4, .count = 20};
    const auto geometry = PathPickerGeometry::measure(placement, PathPickerLimits::results, selection, columns);
    constexpr CellRectangle expected_query{.x = 14, .y = 4, .width = 47, .height = 1};
    constexpr CellRectangle expected_count{.x = 62, .y = 4, .width = 17, .height = 1};
    constexpr std::size_t first_visible = 4;

    check(geometry.query == expected_query && geometry.count_label == expected_count, "root and count labels must leave the original cell budget for the editable query");
    check(geometry.row_count == PathPickerPlacement::maximum_rows && geometry.rows.front().index == first_visible && geometry.rows.back().index == selection, "scrolling must retain the selected match at the end of the visible ranked window");
    const auto flipped = PathPickerPlacement::forPage(host, CellPosition{.x = 10, .y = 28}, PathPickerLimits::results);
    const auto above = PathPickerGeometry::measure(flipped, PathPickerLimits::results, selection, columns);

    check(above.query.y > above.footer.y && above.rows.front().bounds.y > above.rows.back().bounds.y, "an inverted popover must put its field next to the cursor and reverse only the physical row order");
    check(PathPickerGeometry::measure({.area = {.width = 2, .height = 2}}, 1, 0, {}).row_count == 0, "a host too small for the border must expose no actionable row");
  }

  void labelsAndHintsReflectTheCurrentIndexState() {
    features::paths::State state;

    features::paths::open(state, 1, "/work/sub", {});
    features::paths::wait(state, 1);
    check(PathPickerLabels::root(features::paths::page(state).root()) == "sub" && PathPickerLabels::empty(features::paths::page(state)) == "Searching…", "the field must show only the current directory segment while a search is pending");
    constexpr std::uint32_t scanned = 123;

    check(features::paths::receive(state, {.request_id = 1, .root = "/work/sub", .scanned = scanned, .complete = true, .truncated = true}), "the label fixture must adopt its completed index");
    check(PathPickerLabels::count(features::paths::page(state)).view() == "0 of 123" && PathPickerLabels::status(features::paths::page(state)).view() == "123+ paths" && PathPickerLabels::empty(features::paths::page(state)) == "No paths match", "count, truncation and empty-state labels must retain their original wording");
    features::paths::report(state, "Index unavailable");
    check(PathPickerLabels::status(features::paths::page(state)).view() == "Index unavailable" && PathPickerLabels::empty(features::paths::page(state)) == "No paths", "an index failure must use its bounded error and failed empty label");
    const CellRectangle footer{.width = PathPickerPlacement::maximum_width, .height = 1};
    const auto measure = [](std::string_view value) {
      return value.size();
    };

    const auto hints = PathPickerFooter::measure(footer, "123 paths", true, measure);

    check(hints.count == PathPickerFooter::maximum_hints && hints.hints.front().label.key == "↵" && hints.hints.back().label.word == "close", "the macOS footer must retain all five original key and word pairs when they fit");
    check(PathPickerFooter::measure({.width = 1, .height = 1}, "123 paths", false, measure).count == 0, "narrow footers must omit hints instead of overflowing their status");
  }

  const telar::testing::Case case_pages_keep_only_the_current_root_and_request{"path_picker.pages_keep_only_the_current_root_and_request", pagesKeepOnlyTheCurrentRootAndRequest};
  const telar::testing::Case case_failures_keep_only_bounded_utf8_and_tracked_identities{"path_picker.failures_keep_only_bounded_utf8_and_tracked_identities", failuresKeepOnlyBoundedUtf8AndTrackedIdentities};
  const telar::testing::Case case_insertions_preserve_the_selected_shell_word{"path_picker.insertions_preserve_the_selected_shell_word", insertionsPreserveTheSelectedShellWord};
  const telar::testing::Case case_placement_follows_the_cursor_and_the_available_rows{"path_picker.placement_follows_the_cursor_and_the_available_rows", placementFollowsTheCursorAndTheAvailableRows};
  const telar::testing::Case case_path_labels_preserve_the_name_and_highlighted_scalars{"path_picker.path_labels_preserve_the_name_and_highlighted_scalars", pathLabelsPreserveTheNameAndHighlightedScalars};
  const telar::testing::Case case_geometry_keeps_the_query_beside_the_cursor{"path_picker.geometry_keeps_the_query_beside_the_cursor", geometryKeepsTheQueryBesideTheCursor};
  const telar::testing::Case case_labels_and_hints_reflect_the_current_index_state{"path_picker.labels_and_hints_reflect_the_current_index_state", labelsAndHintsReflectTheCurrentIndexState};

}
