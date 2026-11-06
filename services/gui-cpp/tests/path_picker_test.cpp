#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <span>
#include <optional>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "../terminal/cell_position.hpp"
#include <exception>
#include <iostream>
#include <string>

#include "terminal/cell_position.hpp"


import telar.gui.core.unicode_scalar;
import telar.gui.paths.label;
import telar.gui.presentation.form_field_geometry;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

void pagesKeepOnlyTheCurrentRootAndRequest() {
  constexpr std::uint32_t partial_scanned = 12;
  constexpr std::uint32_t completed_scanned = 23;
  PathPickerPage page;
  page.begin(1, "/work");
  require(page.root() == "/work" && page.anchor() == "/work" && page.refreshRequested(), "opening must retain the pane directory and request an index rebuild");
  page.expect(1);
  page.expect(2);
  const std::array highlights{std::uint16_t{1}};
  std::string path = "src/main.cpp";
  const std::array matches{PathMatch{.path = path, .positions = highlights}};
  require(!page.receive({.request_id = 1, .root = "/work", .matches = matches}), "a late page must not replace the latest query");
  require(!page.receive({.request_id = 2, .root = "/other", .matches = matches}), "a current request must still match the current root");
  require(page.receive({.request_id = 2, .root = "/work", .scanned = partial_scanned, .complete = false, .matches = matches}), "an incomplete page must be publishable while the index grows");
  path.assign("destroyed");
  require(page.path(page.matches().front()) == "src/main.cpp" && page.matches().front().highlights().front() == 1, "retained pages must own path bytes and highlighting positions");
  require(page.pendingRequest() == 2 && !page.complete() && !page.refreshRequested(), "partial results must retain the current request without another rebuild");
  require(page.receive({.request_id = 2, .root = "/work", .scanned = completed_scanned, .complete = true, .truncated = true}), "the completed page must retire the current correlation");
  require(page.matches().empty() && page.pendingRequest() == 0 && page.scanned() == completed_scanned && page.truncated(), "a final empty result must replace the preceding page and its metadata");
  require(page.fail({.request_id = 1, .message = "old failure"}) && page.phase() == PathPickerPhase::ready, "tracked obsolete failures must be consumed without replacing the displayed state");
  page.expect(3);
  page.close();
  require(!page.receive({.request_id = 3, .root = "/work", .complete = true}), "closing must reject late pages");
  require(page.fail({.request_id = 3, .message = "late failure"}) && page.phase() == PathPickerPhase::idle, "closing must still recognize late failures without reopening the picker");
}

void failuresKeepOnlyBoundedUtf8AndTrackedIdentities() {
  PathPickerPage page;
  page.begin(1, "/work");
  for (std::size_t index = 1; index <= PathPickerLimits::tracked_requests + 1; ++index) {
    page.expect(index);
  }

  require(!page.fail({.request_id = 1, .message = "untracked"}), "an evicted request must not claim another failure");
  const std::string leading(PathPickerLimits::error_bytes - 1, 'x');
  const auto message = leading + "🧵";
  require(page.fail({.request_id = PathPickerLimits::tracked_requests + 1, .message = message}), "the current request must own its failure");
  require(page.phase() == PathPickerPhase::failed && page.error() == leading && page.pendingRequest() == 0, "failure text must stop at a complete UTF-8 scalar and retire the pending request");
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
  PathPickerPage page;
  page.begin(1, "/work");
  page.setRoot("/work/sub");
  page.expect(1);
  const std::array matches{PathMatch{.path = "a b.txt"}};
  require(page.receive({.request_id = 1, .root = "/work/sub", .complete = true, .matches = matches}), "the insertion fixture must adopt its result");
  const auto relative = PathInsertion::prepare(page, {});
  const auto absolute = PathInsertion::prepare(page, {.absolute = true});
  const auto bracketed = PathInsertion::prepare(page, {.bracketed = true});
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
  PathPickerPage page;
  page.begin(1, "/work/sub");
  page.expect(1);
  require(PathPickerLabels::root(page.root()) == "sub" && PathPickerLabels::empty(page) == "Searching…", "the field must show only the current directory segment while a search is pending");
  constexpr std::uint32_t scanned = 123;
  require(page.receive({.request_id = 1, .root = "/work/sub", .scanned = scanned, .complete = true, .truncated = true}), "the label fixture must adopt its completed index");
  require(PathPickerLabels::count(page).view() == "0 of 123" && PathPickerLabels::status(page).view() == "123+ paths" && PathPickerLabels::empty(page) == "No paths match", "count, truncation and empty-state labels must retain their original wording");
  page.setError("Index unavailable");
  require(PathPickerLabels::status(page).view() == "Index unavailable" && PathPickerLabels::empty(page) == "No paths", "an index failure must use its bounded error and failed empty label");
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
  } catch (const std::exception &error) {
    std::cerr << "gui-path-picker: " << error.what() << '\n';

    return 1;
  }
}
