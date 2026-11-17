#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "assertions.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <optional>
#include <span>
#include <string>
#include <string_view>

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.paths;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::paths;
  using telar::gui::test::require;

  void pagesKeepOnlyTheCurrentRootAndRequest() {
    constexpr std::uint32_t partial_scanned = 12;
    constexpr std::uint32_t completed_scanned = 23;
    features::paths::State state;

    features::paths::open(state, 1, "/work", {});
    require(features::paths::page(state).root() == "/work" && features::paths::page(state).anchor() == "/work" && features::paths::search(state, {}, 1).refresh, "opening must retain the pane directory and request an index rebuild");
    features::paths::wait(state, 1);
    features::paths::wait(state, 2);
    const std::array highlights{std::uint16_t{1}};
    std::string path = "src/main.cpp";
    const std::array matches{PathMatch{.path = path, .positions = highlights}};

    require(!features::paths::receive(state, {.request_id = 1, .root = "/work", .matches = matches}), "a late page must not replace the latest query");
    require(!features::paths::receive(state, {.request_id = 2, .root = "/other", .matches = matches}), "a current request must still match the current root");
    require(features::paths::receive(state, {.request_id = 2, .root = "/work", .scanned = partial_scanned, .complete = false, .matches = matches}), "an incomplete page must be publishable while the index grows");
    path.assign("destroyed");
    require(features::paths::page(state).path(features::paths::page(state).matches().front()) == "src/main.cpp" && features::paths::page(state).matches().front().highlights().front() == 1, "retained pages must own path bytes and highlighting positions");
    require(features::paths::page(state).pendingRequest() == 2 && !features::paths::page(state).complete() && !features::paths::search(state, {}, 1).refresh, "partial results must retain the current request without another rebuild");
    require(features::paths::receive(state, {.request_id = 2, .root = "/work", .scanned = completed_scanned, .complete = true, .truncated = true}), "the completed page must retire the current correlation");
    require(features::paths::page(state).matches().empty() && features::paths::page(state).pendingRequest() == 0 && features::paths::page(state).scanned() == completed_scanned && features::paths::page(state).truncated(), "a final empty result must replace the preceding page and its metadata");
    require(features::paths::fail(state, {.request_id = 1, .message = "old failure"}).has_value() && features::paths::page(state).phase() == PathPickerPhase::ready, "tracked obsolete failures must be consumed without replacing the displayed state");
    features::paths::wait(state, 3);
    features::paths::close(state);
    require(!features::paths::receive(state, {.request_id = 3, .root = "/work", .complete = true}), "closing must reject late pages");
    require(features::paths::fail(state, {.request_id = 3, .message = "late failure"}).has_value() && features::paths::page(state).phase() == PathPickerPhase::idle, "closing must still recognize late failures without reopening the picker");
  }

  void failuresKeepOnlyBoundedUtf8AndTrackedIdentities() {
    features::paths::State state;

    features::paths::open(state, 1, "/work", {});
    for (std::size_t index = 1; index <= PathPickerLimits::tracked_requests + 1; ++index) {
      features::paths::wait(state, index);
    }

    require(!features::paths::fail(state, {.request_id = 1, .message = "untracked"}).has_value(), "an evicted request must not claim another failure");
    const std::string leading(PathPickerLimits::error_bytes - 1, 'x');
    const auto message = leading + "🧵";

    require(features::paths::fail(state, {.request_id = PathPickerLimits::tracked_requests + 1, .message = message}).has_value(), "the current request must own its failure");
    require(features::paths::page(state).phase() == PathPickerPhase::failed && features::paths::page(state).error() == leading && features::paths::page(state).pendingRequest() == 0, "failure text must stop at a complete UTF-8 scalar and retire the pending request");
  }

  void insertionsPreserveTheSelectedShellWord() {
    const auto quoted = PathInsertion::quote("a b'c");
    const auto option = PathInsertion::quote("-a b");
    const auto plain = PathInsertion::quote("file.cpp");

    require(quoted && quoted->view() == "'a b'\\''c'", "shell quoting must preserve spaces and embedded single quotes");
    require(option && option->view() == "./'-a b'", "option-like names must remain paths after quoting");
    require(plain && plain->view() == "file.cpp", "plain paths must not acquire unnecessary quotes");
    require(!PathInsertion::relativeTo("/work", "/worktree/file"), "a path sharing a name prefix must not become relative");
    require(PathInsertion::relativeTo("/", "/file") == std::optional<std::string_view>{"file"}, "the filesystem root must not require a second separator");
    features::paths::State state;
    const std::array directories{PathMatch{.path = "sub/", .kind = PathKind::directory}};

    features::paths::open(state, 1, "/work", {});
    features::paths::wait(state, 1);
    require(features::paths::receive(state, {.request_id = 1, .root = "/work", .complete = true, .matches = directories}) && features::paths::descend(state, 0), "the insertion fixture must browse into its directory");
    features::paths::wait(state, 2);
    const std::array matches{PathMatch{.path = "a b.txt"}};

    require(features::paths::receive(state, {.request_id = 2, .root = "/work/sub", .complete = true, .matches = matches}), "the insertion fixture must adopt its result");
    const auto relative = features::paths::insertion(state, {});
    const auto absolute = features::paths::insertion(state, {.absolute = true});
    const auto bracketed = features::paths::insertion(state, {.bracketed = true});

    require(relative && relative->view() == "'sub/a b.txt'", "nested paths must remain relative to the opening directory");
    require(absolute && absolute->view() == "'/work/sub/a b.txt'", "alternate submission must preserve the absolute path");
    require(bracketed && bracketed->view() == "\x1b[200~'sub/a b.txt'\x1b[201~", "bracketed paste must be encoded as one complete delivery");
  }

  void placementFollowsTheCursorAndTheAvailableRows() {
    const CellRectangle host{.width = 100, .height = 30};
    constexpr CellRectangle expected_below{.x = 8, .y = 3, .width = 72, .height = 14};
    constexpr CellRectangle expected_above{.x = 28, .y = 14, .width = 72, .height = 14};
    constexpr CellRectangle expected_absent{.x = 14, .y = 8, .width = 72, .height = 5};
    const auto below = PathPickerPlacement::forPage(host, CellPosition{.x = 10, .y = 2}, PathPickerLimits::results);

    require(!below.flipped && below.area == expected_below, "a picker with room must open below the cursor");
    const auto above = PathPickerPlacement::forPage(host, CellPosition{.x = 90, .y = 28}, PathPickerLimits::results);

    require(above.flipped && above.area == expected_above, "a low cursor must keep the field beside it and the matches above");
    const auto absent = PathPickerPlacement::forPage(host, {}, 0);

    require(!absent.flipped && absent.area == expected_absent, "a missing cursor must use the original centered fallback");
  }

  void pathLabelsPreserveTheNameAndHighlightedScalars() {
    PathLabel label;
    constexpr std::uint16_t wide_columns = 80;
    constexpr std::uint16_t compact_columns = 10;
    const std::array positions{std::uint16_t{5}};

    label.layout("src/main.cpp", positions, wide_columns);
    require(label.runs().size() == 4 && label.runs()[0].text == "src/" && label.runs()[0].tone == PathLabelTone::directory && label.runs()[2].text == "a" && label.runs()[2].tone == PathLabelTone::match, "path labels must separate directory, name and highlighted characters");
    label.layout("deep/directory/file.cpp", {}, compact_columns);
    require(label.runs().size() == 3 && label.runs()[0].text == "d" && label.runs()[1].tone == PathLabelTone::ellipsis && label.runs()[2].text == "file.cpp", "truncation must remove the directory middle before the filename");
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

    require(geometry.query == expected_query && geometry.count_label == expected_count, "root and count labels must leave the original cell budget for the editable query");
    require(geometry.row_count == PathPickerPlacement::maximum_rows && geometry.rows.front().index == first_visible && geometry.rows.back().index == selection, "scrolling must retain the selected match at the end of the visible ranked window");
    const auto flipped = PathPickerPlacement::forPage(host, CellPosition{.x = 10, .y = 28}, PathPickerLimits::results);
    const auto above = PathPickerGeometry::measure(flipped, PathPickerLimits::results, selection, columns);

    require(above.query.y > above.footer.y && above.rows.front().bounds.y > above.rows.back().bounds.y, "an inverted popover must put its field next to the cursor and reverse only the physical row order");
    require(PathPickerGeometry::measure({.area = {.width = 2, .height = 2}}, 1, 0, {}).row_count == 0, "a host too small for the border must expose no actionable row");
  }

  void labelsAndHintsReflectTheCurrentIndexState() {
    features::paths::State state;

    features::paths::open(state, 1, "/work/sub", {});
    features::paths::wait(state, 1);
    require(PathPickerLabels::root(features::paths::page(state).root()) == "sub" && PathPickerLabels::empty(features::paths::page(state)) == "Searching…", "the field must show only the current directory segment while a search is pending");
    constexpr std::uint32_t scanned = 123;

    require(features::paths::receive(state, {.request_id = 1, .root = "/work/sub", .scanned = scanned, .complete = true, .truncated = true}), "the label fixture must adopt its completed index");
    require(PathPickerLabels::count(features::paths::page(state)).view() == "0 of 123" && PathPickerLabels::status(features::paths::page(state)).view() == "123+ paths" && PathPickerLabels::empty(features::paths::page(state)) == "No paths match", "count, truncation and empty-state labels must retain their original wording");
    features::paths::report(state, "Index unavailable");
    require(PathPickerLabels::status(features::paths::page(state)).view() == "Index unavailable" && PathPickerLabels::empty(features::paths::page(state)) == "No paths", "an index failure must use its bounded error and failed empty label");
    const CellRectangle footer{.width = PathPickerPlacement::maximum_width, .height = 1};
    const auto measure = [](std::string_view value) {
      return value.size();
    };

    const auto hints = PathPickerFooter::measure(footer, "123 paths", true, measure);

    require(hints.count == PathPickerFooter::maximum_hints && hints.hints.front().label.key == "↵" && hints.hints.back().label.word == "close", "the macOS footer must retain all five original key and word pairs when they fit");
    require(PathPickerFooter::measure({.width = 1, .height = 1}, "123 paths", false, measure).count == 0, "narrow footers must omit hints instead of overflowing their status");
  }

}

int main() {
  try {
    pagesKeepOnlyTheCurrentRootAndRequest();
    failuresKeepOnlyBoundedUtf8AndTrackedIdentities();
    insertionsPreserveTheSelectedShellWord();
    placementFollowsTheCursorAndTheAvailableRows();
    pathLabelsPreserveTheNameAndHighlightedScalars();
    geometryKeepsTheQueryBesideTheCursor();
    labelsAndHintsReflectTheCurrentIndexState();
    std::cout << "gui-path-picker: passed\n";
  } catch (const std::exception& error) {
    std::cerr << "gui-path-picker: " << error.what() << '\n';

    return 1;
  }
}
