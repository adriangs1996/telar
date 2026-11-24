#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  void testTheExplorerAsksForAPaneAndReturns() {
    Explorer explorer;

    explorer.start();
    check(!explorer.view.pinned && explorer.view.focused, "over the panes it has the keys");
    // The pane is the tab's to give: the keys only ask for it.
    check(explorer.type("<C-w>T").kind == ActionKind::pin && !explorer.view.pinned && explorer.view.open);
    pin(explorer.view, true);
    check(explorer.view.pinned && explorer.view.focused, "it has the keys when it takes its pane");

    const auto shown = hints(explorer.view, explorer.state, explorer.context());

    check(std::ranges::any_of(shown.items.view().first(shown.count), [](const Hint& hint) {
      return hint.keys.view() == "<C-w>T" && hint.label.view() == "over the panes";
    }),
        "its hints say the way back");

    // As a pane it leaves the keys and takes them; over the panes it always has them.
    focus(explorer.view, false);
    check(!explorer.view.focused);
    focus(explorer.view, true);
    explorer.type(":");
    check(explorer.enter("pin").kind == ActionKind::unpin && explorer.view.pinned, "and asks to leave its pane the same way");
    pin(explorer.view, false);
    focus(explorer.view, false);
    check(explorer.view.focused, "which it cannot leave while it covers them");
  }

  void testTheKeysThatMoveBetweenPanesGoThroughItsWindows() {
    Explorer explorer;

    explorer.start();
    pin(explorer.view, true);
    check(!toward(explorer.view, Side::left) && !toward(explorer.view, Side::right) && !toward(explorer.view, Side::up) && !toward(explorer.view, Side::down) && explorer.view.current == 0, "with one window the panes are what is on every side");

    // Two windows side by side: the key goes from one to the other before it leaves.
    explorer.type("<C-w>v");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1);
    check(!toward(explorer.view, Side::right) && explorer.view.current == 1, "past the last one are the panes");
    check(toward(explorer.view, Side::left) && explorer.view.current == 0, "to its window on that side first");
    check(!toward(explorer.view, Side::left) && explorer.view.current == 0, "and past the first one to the panes");
    check(toward(explorer.view, Side::right) && explorer.view.current == 1);
    check(!toward(explorer.view, Side::up) && !toward(explorer.view, Side::down), "and across them there is no window");

    // One above the other: up and down move between them, and left and right leave from either.
    explorer.type("<C-w>o");
    explorer.type("<C-w>s");
    check(explorer.view.windows.size() == 2 && !explorer.view.side_by_side && explorer.view.current == 1);
    check(toward(explorer.view, Side::up) && explorer.view.current == 0 && toward(explorer.view, Side::down) && explorer.view.current == 1);
    check(!toward(explorer.view, Side::left) && !toward(explorer.view, Side::right) && explorer.view.current == 1);
  }

  // What the runtime keeps of an explorer that stands as a pane is where its windows are and how
  // they list; the explorer is put back from it.
  void testItsWindowsAreKeptAndPutBack() {
    Explorer explorer;

    explorer.start();
    explorer.type("F");
    explorer.type("l");
    explorer.type("j");
    explorer.type("S");
    explorer.type("g.");

    KeptWindows kept{};
    const auto context = explorer.context();
    const auto count = keptWindows(kept, explorer.view, context);
    const auto& window = *explorer.view.windows[0];

    check(count == 1 && kept[0].machine.empty() && kept[0].root == window.root.view() && kept[0].selected == window.selected.view() && !kept[0].selected.empty(), "a window of the machine that keeps it names none");
    check(kept[0].sort == window.sort && kept[0].sort != Sort::name && kept[0].hidden && !kept[0].follow && kept[0].lens == Lens::tree);

    // Moving in a window is nothing its runtime is told; where the window is, is.
    const auto mark = keptMark(explorer.view);

    explorer.type("j");
    check(keptMark(explorer.view) == mark, "the row selected is no part of the mark");
    explorer.type("S");
    check(keptMark(explorer.view) != mark, "how it lists is");

    // Another explorer takes them: the same place, the same row, the same way of listing.
    const std::string root{kept[0].root};
    const std::string selected{kept[0].selected};
    const std::array<ExplorerWindow, 2> layout{{
        {.root = root, .selected = selected, .lens = Lens::tree, .sort = Sort::size, .scope = Scope::workspace, .follow = false, .hidden = true},
        {.machine = "nowhere", .root = "/srv", .lens = Lens::changes},
    }};
    Explorer other;

    other.start();
    restore(other.view, other.context(), {.windows = layout, .current = 1, .side_by_side = false});
    check(other.view.windows.size() == 2 && other.view.current == 1 && !other.view.side_by_side);

    const auto& first = *other.view.windows[0];
    const auto& second = *other.view.windows[1];

    check(first.root.view() == root && first.selected.view() == selected && first.sort == Sort::size && first.hidden && !first.follow && first.machine == other.context().host);
    check(second.machine == other.context().host && second.follow && second.lens == Lens::changes, "a window of a machine this one does not keep follows the pane, on the host");
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

  const telar::testing::Case case_beside{"pinned.the_explorer_asks_for_a_pane_and_returns", testTheExplorerAsksForAPaneAndReturns};
  const telar::testing::Case case_kept{"pinned.its_windows_are_kept_and_put_back", testItsWindowsAreKeptAndPutBack};
  const telar::testing::Case case_steps{"pinned.the_keys_that_move_between_panes_go_through_its_windows", testTheKeysThatMoveBetweenPanesGoThroughItsWindows};
  const telar::testing::Case case_hand{"pinned.a_pane_takes_the_rows_dropped_on_it_as_enter_gives_them", testAPaneTakesTheRowsDroppedOnItAsEnterGivesThem};

}
