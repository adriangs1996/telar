#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.gui.input.copy_pointer;
import telar.gui.terminal.font_grid;
import telar.gui.terminal.copy_mode;

namespace {

using namespace telar::gui;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <typename Value>
const Value &requiredValue(const std::optional<Value> &value) {
  if (!value) {
    throw std::runtime_error{"Expected an engaged copy-mode test value"};
  }

  return *value;
}

struct GridFixture {
  static constexpr std::uint16_t columns = 10;
  static constexpr std::uint16_t rows = 4;
  static constexpr std::uint16_t separator_column = 5;
  static constexpr std::uint16_t last_text_column = 8;
  static constexpr std::size_t cell_count = static_cast<std::size_t>(columns) * rows;
  std::array<CellValue, cell_count> cells{};

  GridFixture() {
    constexpr std::string_view text = "  foo/bar "
                                      "baz   end "
                                      "          "
                                      "last row  ";
    for (std::size_t index = 0; index < cells.size(); ++index) {
      cells[index].text[0] = static_cast<telar::Byte>(text[index]);
    }
  }

  [[nodiscard]] CopyGrid grid() const noexcept {
    return {.cells = cells, .columns = columns, .rows = rows, .scroll = {.total_rows = rows}};
  }
};

void motionAndSelection() {
  const GridFixture fixture;
  const auto grid = fixture.grid();
  CopyMode mode;
  require(mode.enter(1, grid, {.visible = true, .x = 2}), "copy mode must start at the terminal cursor");
  const auto word = mode.key({.codepoint = 'w'}, grid);
  require(word && requiredValue(word).next && requiredValue(requiredValue(word).next).cursor == CopyPoint{.x = GridFixture::separator_column, .y = 0}, "word motion must distinguish punctuation from letters");
  require(mode.commit(requiredValue(word)), "current copy plans must commit");
  const auto select = mode.key({.codepoint = 'v'}, grid);
  require(select && mode.commit(requiredValue(select)), "character selection must start at the copy cursor");
  const auto end = mode.key({.codepoint = '$'}, grid);
  require(end && mode.commit(requiredValue(end)) && requiredValue(mode.state()).cursor.x == GridFixture::last_text_column, "line-end motion must ignore trailing padding");
  const auto copy = mode.key({.codepoint = 'y'}, grid);
  require(copy && !requiredValue(copy).next && requiredValue(copy).selection && requiredValue(requiredValue(copy).selection).start_x == GridFixture::separator_column && requiredValue(requiredValue(copy).selection).end_x == GridFixture::last_text_column && !requiredValue(requiredValue(copy).selection).linewise, "copy must retain inclusive history coordinates before leaving");
  require(mode.commit(requiredValue(copy)) && !mode.active() && !mode.commit(requiredValue(copy)), "a copy plan must apply at most once");
}

void viewportAndPruning() {
  const GridFixture fixture;
  auto grid = fixture.grid();
  constexpr std::uint32_t total_rows = 100;
  constexpr std::uint32_t offset = 96;
  grid.scroll = {.total_rows = total_rows, .offset = offset};
  CopyMode mode;
  require(mode.enter(1, grid, {.visible = false}) && requiredValue(mode.state()).cursor.y == total_rows - 1, "a hidden terminal cursor must start at the viewport's last row");
  const auto top = mode.key({.codepoint = 'g'}, grid);
  require(top && requiredValue(top).viewport && requiredValue(requiredValue(top).viewport).offset == 0 && mode.commit(requiredValue(top)), "top motion must request history row zero");
  grid.scroll.offset = 0;
  const auto leave = mode.leave(grid);
  require(leave.viewport && leave.viewport.value().offset == offset, "leaving keyboard copy mode must restore its entry viewport");
  mode.reset();
  grid.scroll.offset = offset;
  require(mode.enter(1, grid, {.visible = true, .y = 2}), "copy mode must allow a new activation");
  const auto selection = mode.key({.codepoint = 'v'}, grid);
  require(selection && mode.commit(requiredValue(selection)), "pruning fixture must establish an anchor");
  grid.scroll = {.total_rows = total_rows - GridFixture::rows, .offset = offset - GridFixture::rows};
  mode.onFrame(offset, grid);
  require(requiredValue(mode.state()).cursor.y == total_rows - GridFixture::rows - 2 && requiredValue(mode.state()).anchor == requiredValue(mode.state()).cursor, "pruned history must move both selection endpoints");
}

// A match is shown clear of the view's edges, which a pinned separator and a docked line
// cover; a selection under way stretches to it, and none begins without one.
void searchRevealsMatchesWithMargin() {
  constexpr std::uint32_t total = 100;
  constexpr std::uint32_t match_row = 10;
  const GridFixture fixture;
  auto grid = fixture.grid();
  grid.scroll = {.total_rows = total, .offset = total - GridFixture::rows};
  CopyMode mode;
  require(mode.enter(1, grid, {.visible = true}), "margin fixture must enter copy mode");
  const auto search = mode.key({.codepoint = '?'}, grid);
  require(search && mode.commit(requiredValue(search)), "backward search must request input");
  const std::array matches{telar::PaneMatch{.x = 1, .y = match_row, .len = 2}};
  const auto found = mode.search(matches, grid);
  require(found && mode.commit(requiredValue(found)), "a match far above the view must apply");
  const auto &state = requiredValue(mode.state());
  require(state.cursor == CopyPoint{.x = 1, .y = match_row} && !state.anchor, "a match takes the cursor to its start without selecting");
  require(state.viewport_offset == match_row - (GridFixture::rows / 2), "a match out of view comes to the view's middle");
  const auto select = mode.key({.codepoint = 'v'}, grid);
  require(select && mode.commit(requiredValue(select)), "a selection must start at the match");
  const std::array later{telar::PaneMatch{.x = 0, .y = match_row - 2, .len = 2}};
  const auto stretched = mode.search(later, grid);
  require(stretched && mode.commit(requiredValue(stretched)) && requiredValue(mode.state()).anchor == CopyPoint{.x = 1, .y = match_row}, "a search stretches a selection under way to its match");

  // Without a selection, y copies the match the cursor stands on.
  CopyMode plain;
  require(plain.enter(1, grid, {.visible = true}) && plain.commit(requiredValue(plain.key({.codepoint = '?'}, grid))), "a second search must begin");
  require(plain.commit(requiredValue(plain.search(matches, grid))), "its match must apply");
  const auto copy = plain.key({.codepoint = 'y'}, grid);
  const auto &copied = requiredValue(requiredValue(copy).selection);
  require(copied.start_x == 1 && copied.end_x == 2 && copied.start_y == match_row && copied.end_y == match_row && !copied.linewise, "y copies the current match");
}

void searchAndTransactionalPlans() {
  const GridFixture fixture;
  const auto grid = fixture.grid();
  CopyMode mode;
  require(mode.enter(1, grid, {.visible = true}), "search fixture must enter copy mode");
  const auto search = mode.key({.codepoint = '/'}, grid);
  require(search && requiredValue(search).effect.search == CopyDirection::forward && mode.commit(requiredValue(search)), "forward search must request input even when its direction is unchanged");
  const std::array matches{telar::PaneMatch{.x = 2, .y = 0, .len = 3}, telar::PaneMatch{.x = 0, .y = 1, .len = 3}};
  const auto found = mode.search(matches, grid);
  require(found && mode.matches().empty(), "planning search results must preserve existing match ownership");
  require(mode.commit(requiredValue(found)) && mode.matches().size() == matches.size() && requiredValue(mode.state()).cursor == CopyPoint{.x = 2, .y = 0} && !requiredValue(mode.state()).anchor, "committing matches must move to the first result strictly after the cursor, at its start, without selecting");
  const auto next = mode.key({.codepoint = 'n'}, grid);
  require(next && mode.commit(requiredValue(next)) && requiredValue(mode.state()).cursor == CopyPoint{.x = 0, .y = 1}, "search navigation must advance to the next match");
  const auto wrapped = mode.key({.codepoint = 'n'}, grid);
  require(wrapped && mode.commit(requiredValue(wrapped)) && requiredValue(mode.state()).cursor == CopyPoint{.x = 2, .y = 0}, "search navigation must wrap around");
  const auto stale = mode.key({.codepoint = 'v'}, grid);
  mode.onFrame(0, grid);
  require(stale && mode.current(requiredValue(stale)), "an unchanged frame must preserve a current copy plan");
  auto changed_grid = grid;
  changed_grid.scroll = {.total_rows = GridFixture::rows + 1, .offset = 1};
  mode.onFrame(0, changed_grid);
  require(stale && !mode.commit(requiredValue(stale)), "a frame must invalidate an outstanding navigation plan");
}

void pointerAndProjection() {
  const GridFixture fixture;
  const auto grid = fixture.grid();
  CopyState state{.pane_id = 1, .cursor = {.x = 3, .y = 0}};
  state.beginPointer(CopyGranularity::word, grid);
  require(state.anchor == CopyPoint{.x = 2, .y = 0} && state.cursor == CopyPoint{.x = GridFixture::last_text_column, .y = 0}, "pointer words must preserve paths and punctuation");
  state.movePointer({.x = 1, .y = 1}, grid);
  require(state.anchor == CopyPoint{.x = 2, .y = 0} && state.cursor == CopyPoint{.x = 2, .y = 1}, "word dragging must retain the original word boundary");
  const auto selected = state.selection(grid);
  require(selected.contains(2) && selected.contains(GridFixture::columns + 2) && !selected.contains(1), "copy highlighting must project inclusive absolute coordinates");
  state.toggleSelection(true);
  const auto line = state.selection(grid);
  require(line.contains(GridFixture::columns) && line.contains((GridFixture::columns * 2) - 1), "linewise selection must cover the complete terminal row");
}

void clickTiming() {
  ClickTracker clicks;
  constexpr CopyPoint position{.x = 2, .y = 1};
  require(clicks.press(position, 0) == CopyGranularity::character, "the first press must select characters");
  require(clicks.press(position, ClickTracker::interval_ns) == CopyGranularity::word, "a press at the inclusive interval boundary must select a word");
  require(clicks.press({.x = position.x + 1, .y = position.y}, ClickTracker::interval_ns) == CopyGranularity::line, "one cell of horizontal motion must preserve a triple click");
  require(clicks.press(position, 0) == CopyGranularity::line, "clock regression must use saturating elapsed time");
  require(clicks.press(position, ClickTracker::interval_ns + 1) == CopyGranularity::character, "a late click must begin another gesture");
  require(clicks.press({.x = position.x, .y = position.y + 1}, ClickTracker::interval_ns + 1) == CopyGranularity::character, "changing rows must restart click counting");
}

void pointerOwnership() {
  const GridFixture fixture;
  const auto grid = fixture.grid();
  CopyMode mode;
  require(mode.beginPointer({.pane_id = 1, .position = {.x = 2}}, grid), "a valid press must acquire pointer ownership");
  const auto released = mode.pointer({.x = 4}, grid, true);
  require(released && released->selection && mode.commit(*released), "a drag release must stage an inclusive runtime copy");
  mode.finishPointer();
  const auto retained = mode.pointerOwner();
  require(retained && !retained->dragging && !mode.active(), "completed highlighting must remain disposable without capturing the keyboard");
  require(mode.clearPointer() && !mode.state(), "typing must discard retained highlighting");
  require(mode.beginPointer({.pane_id = 1, .position = {.x = 2}, .now_ns = 1}, grid), "a subsequent press must remain on the same click timeline");
  require(mode.state() && mode.state()->pointer && mode.state()->pointer->granularity == CopyGranularity::word, "a second click must expand the original word");
  auto resized = grid;
  --resized.columns;
  mode.onFrame(0, resized);
  const auto quarantined = mode.pointerOwner();
  require(!mode.state() && quarantined && quarantined->dragging, "resizing must clear highlighting while retaining the physical release owner");
  mode.finishPointer();
  require(!mode.pointerOwner(), "the delayed release must retire the quarantined owner");
}

void wheelFractionsAndBounds() {
  WheelAccumulator wheel;
  constexpr double first_fraction = 0.4;
  constexpr double crossing_fraction = 0.7;
  constexpr double almost_one_line = 0.9;
  constexpr double small_fraction = 0.2;
  require(wheel.consume({.delta = first_fraction}) == 0 && wheel.consume({.delta = crossing_fraction}) == 1, "fractional scroll samples must accumulate before producing a line");
  require(wheel.consume({.delta = almost_one_line, .phase = ScrollPhase::begin}) == 0, "a new scroll gesture must reset the previous fraction");
  require(wheel.consume({.phase = ScrollPhase::cancel}) == 0 && wheel.consume({.delta = small_fraction}) == 0, "cancelled momentum must not leak into the next gesture");
  wheel.reset();
  require(wheel.consume({.delta = 1, .cell_height = 2, .precise = true}) == 0 && wheel.consume({.delta = 1, .cell_height = 2, .precise = true}) == 1, "precise samples must use cell height before viewport row scaling");
  require(wheel.consume({.delta = std::numeric_limits<double>::max()}) == WheelAccumulator::maximum_lines, "a single event must have bounded scroll work");
  require(wheel.consume({.delta = std::numeric_limits<double>::quiet_NaN()}) == 0, "nonfinite host input must not enter integer conversion");
}

}

int main() {
  try {
    motionAndSelection();
    viewportAndPruning();
    searchAndTransactionalPlans();
    searchRevealsMatchesWithMargin();
    pointerAndProjection();
    clickTiming();
    pointerOwnership();
    wheelFractionsAndBounds();
    std::puts("gui-copy-mode: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-copy-mode: " << error.what() << '\n';

    return 1;
  }
}
