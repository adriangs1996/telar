#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  // Where each row of the current window starts, as the list is laid.
  std::vector<std::uint32_t> offsets(const Explorer& explorer) {
    std::vector<std::uint32_t> result;

    for (const auto& row : window(explorer.view).rows) {
      result.push_back(row.offset);
    }

    return result;
  }

  // The rows the window shows are whole in its room, and the next one would not be.
  bool fills(const Window& shown) {
    const auto start = shown.rows[shown.top].offset;
    const auto last = shown.top + shown.page - 1;
    const auto end = shown.rows[last].offset + tall(shown.rows[last].kind);
    const bool next = last + 1 < shown.rows.size() && shown.rows[last + 1].offset + tall(shown.rows[last + 1].kind) - start <= shown.room;

    return end - start <= shown.room && !next;
  }

  void testARowIsAsTallAsItsKind() {
    Explorer explorer;

    check(tall(RowKind::entry) == 2200 && tall(RowKind::change) == 2200 && tall(RowKind::pane) == 2200 && tall(RowKind::added) == 2200 && tall(RowKind::match) == 2200);
    check(tall(RowKind::header) == 2575 && tall(RowKind::note) == 2850 && tall(RowKind::diff) == 1705, "a heading, a note and a line of a diff have the design's heights");

    // A tree of entries alone falls on the pitch of an entry.
    explorer.start();
    const auto tree = offsets(explorer);

    for (std::size_t index = 0; index < tree.size(); ++index) {
      check(window(explorer.view).rows[index].kind != RowKind::entry || tree[index] == index * RowHeights::entry, "an entry of the tree starts a pitch below the one above");
    }

    // The changes: a heading, a file, a heading, a file with its diff unfolded, a heading, a path.
    explorer.type("2gtj=");
    check(explorer.names() == std::vector<std::string>{"Staged", "docs/remote.md", "Unstaged", "docs/usage.md", "@@ -1,2 +1,2 @@", "-old", "+new", " context", "Untracked", ".github/"});
    check(offsets(explorer) == std::vector<std::uint32_t>{0, 2575, 4775, 7350, 9550, 11255, 12960, 14665, 16370, 18945}, "each row starts where the one above ends, by its own height");
  }

  void testTheWindowShowsWhatFitsItsRoom() {
    Explorer explorer;

    explorer.start();
    explorer.type("2gtj=");

    // Room for the first heading, a file, the next heading and a file: 9550, and a little more.
    resize(explorer.view, {.window = 0, .room = 10000});

    const auto& shown = window(explorer.view);

    check(shown.top == 0 && shown.page == 4 && fills(shown), "it shows the rows that fit whole, by their heights");
    check(shown.cursor == 3);

    // The selection goes below what shows: the list moves the least that shows it whole.
    explorer.type("G");
    check(shown.cursor == 9 && shown.top + shown.page == shown.rows.size() && fills(shown), "at the end it shows the last rows, and no room is left below them");
    check(shown.top == 5, "four lines of a diff, a heading and a path take what two headings and two files did");
    explorer.type("gg");
    check(shown.top == 0 && shown.cursor == 1 && shown.page == 4, "back at the top");

    // One row down past the last that shows.
    explorer.type("jj");
    check(shown.cursor == 9, "the selection skips what is no entry");
    explorer.type("gg");

    // The wheel moves it by rows and stops where the rows end.
    scroll(explorer.view, {.window = 0, .count = 3});
    check(shown.top == 3 && fills(shown) && shown.page == 5, "three rows down, where more of the shorter rows fit");
    scroll(explorer.view, {.window = 0, .count = 30});
    check(shown.top == 5 && shown.top + shown.page == shown.rows.size(), "the wheel stops with the last row at the bottom");
    scroll(explorer.view, {.window = 0, .count = -30});
    check(shown.top == 0 && shown.page == 4);

    // Half a page is half the rows that show.
    explorer.type("gg");
    explorer.type("<C-d>");
    check(shown.cursor >= 3 && shown.cursor >= shown.top && shown.cursor < shown.top + shown.page, "half a page down leaves the selection in what shows");

    // A room no row fits in shows one row all the same.
    resize(explorer.view, {.window = 0, .room = 1});
    check(shown.page == 1 && shown.room == RowHeights::entry);

    // With nothing listed, half a page is still measured by entries.
    explorer.type("1gt:");
    explorer.enter("e /home/dev/telar/src");
    explorer.type("2gt");
    resize(explorer.view, {.window = 0, .room = 22000});
    check(window(explorer.view).rows.empty() && window(explorer.view).page == 10);
  }

  void testTheRowsStayLaidAsTheyChange() {
    Explorer explorer;

    explorer.start();
    explorer.type("2gtj=");
    resize(explorer.view, {.window = 0, .room = 10000});
    explorer.type("G");
    check(window(explorer.view).top == 5);

    // The diff folds again: fewer rows, and what shows ends where they end.
    explorer.type("ggj=");

    const auto& shown = window(explorer.view);

    check(explorer.names() == std::vector<std::string>{"Staged", "docs/remote.md", "Unstaged", "docs/usage.md", "Untracked", ".github/"});
    check(offsets(explorer) == std::vector<std::uint32_t>{0, 2575, 4775, 7350, 9550, 12125});
    check(shown.top + shown.page <= shown.rows.size() && fills(shown));

    // A new window shows as much as the one it was made from.
    explorer.type("<C-w>v");
    check(explorer.view.windows.size() == 2 && window(explorer.view).room == 10000, "a window made from another is as tall until it is told");
  }

  const telar::testing::Case case_tall{"heights.a_row_is_as_tall_as_its_kind", testARowIsAsTallAsItsKind};
  const telar::testing::Case case_room{"heights.the_window_shows_what_fits_its_room", testTheWindowShowsWhatFitsItsRoom};
  const telar::testing::Case case_laid{"heights.the_rows_stay_laid_as_they_change", testTheRowsStayLaidAsTheyChange};

}
