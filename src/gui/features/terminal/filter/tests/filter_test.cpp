#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import telar.testing;
import telar.gui.foundation.terminal;
import telar.gui.features.terminal.filter;
import telar.wire.content;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;

  namespace filter = telar::gui::features::terminal::filter;

  constexpr std::uint16_t columns = 12;

  // Rows of `columns` cells, a line each, as a screen or the runtime holds them.
  struct Rows {
    std::vector<CellValue> cells;
    std::vector<Byte> flags;
  };

  Rows rowsOf(const std::vector<std::string_view>& lines) {
    Rows rows;

    for (const auto line : lines) {
      for (std::size_t column = 0; column < columns; ++column) {
        const auto text = column < line.size() ? line.substr(column, 1) : std::string_view{" "};

        rows.cells.emplace_back(Cell{.text = byteView(text)});
      }

      rows.flags.push_back(0);
    }

    return rows;
  }

  filter::ScreenRows screenOf(const Rows& rows, std::uint64_t first, std::uint64_t revision = 1) {
    return {.first = first, .columns = columns, .cells = rows.cells, .flags = rows.flags, .revision = revision};
  }

  // The rows the filter hides, as [first, end) runs.
  std::vector<std::pair<std::uint64_t, std::uint64_t>> hidden(const filter::State& state, const filter::Extent& extent) {
    std::vector<std::pair<std::uint64_t, std::uint64_t>> runs;

    filter::hidden(state, extent, [&](std::uint64_t first, std::uint64_t end) {
      runs.emplace_back(first, end);
    });

    return runs;
  }

  std::string copied(const filter::State& state, Memory& memory) {
    ds::String<Memory> text{memory};

    filter::copy(state, text);
    return std::string{text.view()};
  }

  using Runs = std::vector<std::pair<std::uint64_t, std::uint64_t>>;

  // An output of eight lines from stable row 100, every one on the screen and settled.
  const std::vector<std::string_view> output{"build a", "error: x", "build b", "build c", "warn y", "ERROR: z", "build d", "done"};
  constexpr filter::Extent whole{.first = 100, .end = 108, .settled = 108, .screen = 100};

  // Only the lines that match are shown, with as many lines around them as asked, and a copy
  // takes those lines.
  void showsMatchingLinesWithTheirContext() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    filter::State state{memory};
    const auto rows = rowsOf(output);

    filter::open(state, {.pane_id = 1, .block = 100, .top = 90});
    check(hidden(state, whole).empty(), "an open filter with no query hides nothing");
    check(filter::query(state, {.text = "error"}), "a literal query compiles");
    filter::screen(state, screenOf(rows, 100), whole);
    check(hidden(state, whole) == Runs{{100, 101}, {102, 108}}, "only the line with the text is shown");
    check(filter::status(state).matches == 1 && filter::status(state).complete, "one line matched, every row read");
    check(copied(state, memory) == "error: x", "a copy takes the lines shown");

    check(filter::query(state, {.text = "error", .ignore_case = true, .context = 1}), "the case ignored, a line of context");
    filter::screen(state, screenOf(rows, 100), whole);
    check(hidden(state, whole) == Runs{{103, 104}, {107, 108}}, "each match is shown with a line before and after it");
    check(copied(state, memory) == "build a\nerror: x\nbuild b\nwarn y\nERROR: z\nbuild d", "and copied with them");
    check(filter::close(state) == std::uint64_t{90} && hidden(state, whole).empty(), "closing shows the output whole and gives back where the view was");
  }

  // A regular expression, and inverted: the lines it is not found in.
  void filtersByRegexAndInverted() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    filter::State state{memory};
    const auto rows = rowsOf(output);

    filter::open(state, {.pane_id = 1, .block = 100, .top = 100});
    check(filter::query(state, {.text = "^build [a-c]$", .regex = true}), "a regular expression compiles");
    filter::screen(state, screenOf(rows, 100), whole);
    check(hidden(state, whole) == Runs{{101, 102}, {104, 108}}, "the lines the expression matches whole");
    check(filter::query(state, {.text = "build", .invert = true}), "an inverted query");
    filter::screen(state, screenOf(rows, 100), whole);
    check(copied(state, memory) == "error: x\nwarn y\nERROR: z\ndone", "the lines without the text are shown");

    check(!filter::query(state, {.text = "(unclosed", .regex = true}) && !filter::status(state).error.empty(), "an expression that does not compile says why");
    filter::screen(state, screenOf(rows, 100), whole);
    check(hidden(state, whole).empty(), "and the output stays whole");
  }

  // Rows the screen does not hold are asked of the runtime a request at a time, and read in
  // order as they come.
  void readsRowsTheScreenDoesNotHold() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    filter::State state{memory};
    const auto rows = rowsOf(output);
    constexpr filter::Extent scrolled{.first = 100, .end = 108, .settled = 108, .screen = 104};

    filter::open(state, {.pane_id = 1, .block = 100, .top = 100});
    static_cast<void>(filter::query(state, {.text = "error", .ignore_case = true}));
    const auto wanted = filter::wanted(state, scrolled);

    check(wanted && wanted->from == 100 && wanted->count == 4, "the rows above the screen are asked for");
    filter::asked(state, 7, *wanted);
    check(!filter::wanted(state, scrolled), "one request at a time");

    // The first four rows, as the runtime sends them.
    std::vector<Cell> cells;

    for (std::size_t index = 0; index < 4 * columns; ++index) {
      cells.push_back(Cell{.text = rows.cells[index].utf8().empty() ? byteView(" ") : byteView(rows.cells[index].utf8())});
    }

    std::vector<Byte> encoded(cells.size() * 16);
    const std::vector<Byte> flags(4, 0);
    const PaneRows reply{.request_id = 7, .pane_id = 1, .generation = 1, .from = 100, .cols = columns, .rows = 4, .text_metadata = TextMetadata{.row_flags = flags}, .cells = CellRunCodec::encode(cells, encoded)};

    check(!filter::receive(state, PaneRows{.request_id = 8, .pane_id = 1}, scrolled), "a reply to another request is not the filter's");
    check(filter::receive(state, reply, scrolled), "its own reply is read");
    const Rows below{std::vector<CellValue>(rows.cells.begin() + 4 * columns, rows.cells.end()), std::vector<Byte>(4, 0)};

    filter::screen(state, screenOf(below, 104), scrolled);
    check(hidden(state, scrolled) == Runs{{100, 101}, {102, 105}, {106, 108}}, "rows from the runtime and from the screen are read as one output");
    check(!filter::wanted(state, scrolled), "nothing is left to ask for");
  }

  // While the command prints, the rows that may still change are read again whenever the screen
  // changes them, and the settled ones once.
  void followsTheOutputLive() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    filter::State state{memory};

    filter::open(state, {.pane_id = 1, .block = 100, .top = 100});
    static_cast<void>(filter::query(state, {.text = "fail"}));
    const auto first = rowsOf({"ok 1", "ok 2", "fail 3", "ok 4"});
    constexpr filter::Extent running{.first = 100, .end = 104, .settled = 102, .screen = 100};

    filter::screen(state, screenOf(first, 100, 1), running);
    check(hidden(state, running) == Runs{{100, 102}, {103, 104}}, "a match among the rows still printing is shown at once");
    check(!filter::screen(state, screenOf(first, 100, 1), running), "the same rows are not read again");

    // The last row changed under the cursor, and two more came.
    const auto second = rowsOf({"ok 1", "ok 2", "fail 3", "fail 4", "ok 5", "fail 6"});
    constexpr filter::Extent grown{.first = 100, .end = 106, .settled = 104, .screen = 100};

    check(filter::screen(state, screenOf(second, 100, 2), grown), "changed rows are read again");
    check(hidden(state, grown) == Runs{{100, 102}, {104, 105}}, "the lines that match now are shown");
    check(filter::status(state).matches == 3, "and counted");
  }

  // The matches on a row are marked by the columns they take, wide characters counted.
  void marksTheMatchesOnARow() {
    SystemAllocator system;
    MemoryAdapter memory{system};
    filter::State state{memory};
    std::vector<CellValue> cells;

    cells.emplace_back(Cell{.width = CellWidth::wide, .text = byteView("\xe6\x97\xa5")});
    cells.emplace_back(Cell{.width = CellWidth::continuation, .text = byteView("")});
    for (const auto character : std::string_view{" err err"}) {
      cells.emplace_back(Cell{.text = byteView(std::string_view{&character, 1})});
    }

    filter::open(state, {.pane_id = 1, .block = 100, .top = 100});
    static_cast<void>(filter::query(state, {.text = "err"}));
    ds::Array<filter::Mark, 4> marks{};
    const auto count = filter::highlight(state, cells, marks.viewMut());

    check(count == 2 && marks[0].column == 3 && marks[0].length == 3 && marks[1].column == 7, "each match by its columns, past a wide character");
    static_cast<void>(filter::query(state, {.text = "err", .invert = true}));
    check(filter::highlight(state, cells, marks.viewMut()) == 0, "an inverted filter marks nothing");

    // A row is drawn past its text in blanks, which are not the line's: `$` ends the line there.
    std::vector<CellValue> padded;

    for (const auto character : std::string_view{"ok 1"}) {
      padded.emplace_back(Cell{.text = byteView(std::string_view{&character, 1})});
    }

    for (int blank = 0; blank < 6; ++blank) {
      padded.emplace_back(Cell{.text = byteView(" ")});
    }

    static_cast<void>(filter::query(state, {.text = "^ok [13]$", .regex = true}));
    check(filter::highlight(state, padded, marks.viewMut()) == 1 && marks[0].column == 0 && marks[0].length == 4, "an anchored expression marks the line a row draws");
  }

  const telar::testing::Case case_shows_matching_lines_with_their_context{"filter.shows_matching_lines_with_their_context", showsMatchingLinesWithTheirContext};
  const telar::testing::Case case_filters_by_regex_and_inverted{"filter.filters_by_regex_and_inverted", filtersByRegexAndInverted};
  const telar::testing::Case case_reads_rows_the_screen_does_not_hold{"filter.reads_rows_the_screen_does_not_hold", readsRowsTheScreenDoesNotHold};
  const telar::testing::Case case_follows_the_output_live{"filter.follows_the_output_live", followsTheOutputLive};
  const telar::testing::Case case_marks_the_matches_on_a_row{"filter.marks_the_matches_on_a_row", marksTheMatchesOnARow};

}
