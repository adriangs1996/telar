#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  void testTheExplorerStandsBesideThePanesAndReturns() {
    Explorer explorer;

    explorer.start();
    check(!explorer.view.pinned && explorer.view.focused, "over the panes it has the keys");
    explorer.type("<C-w>T");
    check(explorer.view.pinned && explorer.view.focused && explorer.view.open && explorer.view.message.view() == "beside the panes · <C-w>T puts it over them again");

    // Beside the panes it leaves the keys and takes them; over them it always has them.
    focus(explorer.view, false);
    check(!explorer.view.focused);
    focus(explorer.view, true);
    explorer.type(":");
    explorer.enter("pin");
    check(!explorer.view.pinned && explorer.view.focused && explorer.view.message.view() == "over the panes");
    focus(explorer.view, false);
    check(explorer.view.focused, "which it cannot leave while it covers them");
  }

  void testTheKeysThatMoveBetweenPanesGoThroughItsWindows() {
    Explorer explorer;

    explorer.start();
    explorer.type("<C-w>T");
    check(!toward(explorer.view, Side::left), "with one window the panes are what is at its left");
    check(toward(explorer.view, Side::right) && toward(explorer.view, Side::up) && toward(explorer.view, Side::down) && explorer.view.current == 0, "and nothing any other way");

    // Two windows side by side: the key goes from one to the other before it leaves.
    explorer.type("<C-w>v");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1);
    check(toward(explorer.view, Side::right) && explorer.view.current == 1);
    check(toward(explorer.view, Side::left) && explorer.view.current == 0, "to its window on that side first");
    check(!toward(explorer.view, Side::left) && explorer.view.current == 0, "and past the last one to the panes");
    check(toward(explorer.view, Side::right) && explorer.view.current == 1);

    // One above the other: up and down move between them, and left leaves from either.
    explorer.type("<C-w>o");
    explorer.type("<C-w>s");
    check(explorer.view.windows.size() == 2 && !explorer.view.side_by_side && explorer.view.current == 1);
    check(toward(explorer.view, Side::up) && explorer.view.current == 0 && toward(explorer.view, Side::down) && explorer.view.current == 1);
    check(!toward(explorer.view, Side::left) && explorer.view.current == 1);
  }

  void testAPaneTakesTheRowsDroppedOnItAsEnterGivesThem() {
    Explorer explorer;

    explorer.start();
    explorer.type("F");
    explorer.type("l");

    const auto usage = explorer.at("usage.md");

    // Nothing is dragged: a pane takes nothing.
    check(hand(explorer.view, explorer.state, explorer.context(), 13).kind == ActionKind::none);

    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = usage}) == 1);

    auto action = hand(explorer.view, explorer.state, explorer.context(), 13);

    check(action.kind == ActionKind::insert && action.pane == 13 && explorer.view.text.view() == "usage.md ", "a shell gets the path typed, from where it is");
    check(explorer.view.dragged.empty() && explorer.view.edits.empty(), "and nothing is left to write");

    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = usage}) == 1);
    action = hand(explorer.view, explorer.state, explorer.context(), 11);
    check(action.kind == ActionKind::mention && action.pane == 11 && explorer.view.text.view() == "@docs/usage.md ", "an agent a mention");

    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = usage}) == 1);
    action = hand(explorer.view, explorer.state, explorer.context(), 12);
    check(action.kind == ActionKind::open && action.pane == 12 && explorer.view.paths.size() == 1 && explorer.view.paths[0].view() == "/home/dev/telar/docs/usage.md", "an editor opens it");

    // A pane that is not of the tab takes nothing, and the drag ends.
    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = usage}) == 1);
    check(hand(explorer.view, explorer.state, explorer.context(), 99).kind == ActionKind::none && explorer.view.dragged.empty());
  }

  const telar::testing::Case case_beside{"pinned.the_explorer_stands_beside_the_panes_and_returns", testTheExplorerStandsBesideThePanesAndReturns};
  const telar::testing::Case case_steps{"pinned.the_keys_that_move_between_panes_go_through_its_windows", testTheKeysThatMoveBetweenPanesGoThroughItsWindows};
  const telar::testing::Case case_hand{"pinned.a_pane_takes_the_rows_dropped_on_it_as_enter_gives_them", testAPaneTakesTheRowsDroppedOnItAsEnterGivesThem};

}
