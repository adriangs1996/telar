#include "explorer_fixture.hpp"
#include <string_view>
#include <vector>

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  using Entries = std::vector<MenuEntry>;

  constexpr std::size_t no_row = std::numeric_limits<std::size_t>::max();

  // The lines of the menu that shows, and the ones of them that cannot be chosen.
  Entries entries(const View& view) {
    Entries result;

    for (std::size_t index = 0; index < view.menu.count; ++index) {
      result.push_back(view.menu.items[index].entry);
    }

    return result;
  }

  Entries disabled(const View& view) {
    Entries result;

    for (std::size_t index = 0; index < view.menu.count; ++index) {
      if (!view.menu.items[index].enabled) {
        result.push_back(view.menu.items[index].entry);
      }
    }

    return result;
  }

  std::size_t lineOf(const View& view, MenuEntry entry) {
    for (std::size_t index = 0; index < view.menu.count; ++index) {
      if (view.menu.items[index].entry == entry) {
        return index;
      }
    }

    check(false, "the menu has the line");
    return 0;
  }

  // The pointer asks for the menu of the row named, in the current window.
  void ask(Explorer& explorer, std::string_view name) {
    openMenu(explorer.view, explorer.state, explorer.context(), {.window = explorer.view.current, .row = explorer.at(name)});
    explorer.answer();
  }

  Action choose(Explorer& explorer, MenuEntry entry) {
    const auto action = chooseMenu(explorer.view, explorer.state, explorer.context(), lineOf(explorer.view, entry));

    explorer.answer();
    return action;
  }

  void testTheMenuOfARowListsWhatAppliesToIt() {
    using enum MenuEntry;

    Explorer explorer;

    explorer.start();
    explorer.type("l");

    // A file with changes: toward the panes, the changes typed, where it is, and git.
    ask(explorer, "usage.md");
    check(explorer.view.mode == Mode::menu && explorer.selected() == "/home/dev/telar/docs/usage.md", "the row asked is selected");
    check(entries(explorer.view) == Entries{hand, open, mention, rule, rename, new_file, new_directory, rule, cut, copy, paste, copy_relative, trash, rule, shell_here, change_directory, window_here, rule, diff, stage, unstage, discard});
    check(disabled(explorer.view) == Entries{paste}, "nothing was yanked to paste");

    const auto shown = menu(explorer.view, explorer.state, explorer.context());

    check(shown.count == explorer.view.menu.count && shown.lines[0].current && shown.lines[0].label.view() == "Insert → 3 zsh" && shown.lines[0].keys.view() == "<CR>", "each line says what its key does here");
    check(shown.lines[2].label.view() == "Mention to Claude Code" && shown.lines[2].keys.view() == "@");
    check(shown.lines[3].rule && shown.lines[10].label.view() == "Paste here" && !shown.lines[10].enabled);
    check(shown.lines[15].label.view() == "cd pane 3 here" && shown.lines[6].keys.view() == "o …/");
    check(status(explorer.view, explorer.state, explorer.context(), 0).mode == "NORMAL" && hints(explorer.view, explorer.state, explorer.context()).items[0].keys.view() == "j k");
    cancel(explorer.view, explorer.state, explorer.context());
    check(explorer.view.mode == Mode::normal && menu(explorer.view, explorer.state, explorer.context()).count == 0, "Escape closes it");

    // A directory git has nothing to say of: Enter goes in, no editor opens it, and no git.
    ask(explorer, "assets");
    check(entries(explorer.view) == Entries{hand, open, mention, rule, rename, new_file, new_directory, rule, cut, copy, paste, copy_relative, trash, rule, shell_here, change_directory, window_here});
    check(disabled(explorer.view) == Entries{open, paste} && menu(explorer.view, explorer.state, explorer.context()).lines[0].label.view() == "Enter");
    cancel(explorer.view, explorer.state, explorer.context());

    // With an agent focused a shell's cd has no pane, and with changes typed the plan is a line away.
    explorer.focused = 11;
    explorer.type("F");
    explorer.type("yy");
    explorer.type("dd");
    ask(explorer, "usage.md");
    check(disabled(explorer.view) == Entries{change_directory} && entries(explorer.view).back() == write);
    check(menu(explorer.view, explorer.state, explorer.context()).lines[explorer.view.menu.count - 1].label.view() == "Apply 1 change…");
    check(menu(explorer.view, explorer.state, explorer.context()).lines[0].label.view() == "Mention → 1 Claude Code");
    cancel(explorer.view, explorer.state, explorer.context());

    // A changed path, in the list of changes: nothing is renamed or added there.
    explorer.type("gt");
    ask(explorer, "usage.md");
    check(disabled(explorer.view) == Entries{rename, new_file, new_directory, change_directory});
    cancel(explorer.view, explorer.state, explorer.context());

    // No row: what the window itself takes.
    openMenu(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = no_row});
    check(entries(explorer.view) == Entries{new_file, new_directory, paste, rule, new_window, write} && disabled(explorer.view) == Entries{new_file, new_directory});
  }

  void testTheKeysMoveInTheMenuAndALineRunsWhatItsKeyRuns() {
    using enum MenuEntry;

    Explorer explorer;

    explorer.start();
    explorer.type("l");
    ask(explorer, "assets");
    check(explorer.view.menu.current == 0);
    explorer.type("j");
    check(explorer.view.menu.items[explorer.view.menu.current].entry == mention, "a line that cannot be chosen is passed over");
    explorer.type("j");
    check(explorer.view.menu.items[explorer.view.menu.current].entry == rename, "and so is a rule");
    explorer.type("kkk");
    check(explorer.view.menu.items[explorer.view.menu.current].entry == window_here, "the ends meet");
    explorer.type("q");
    check(explorer.view.mode == Mode::normal);

    // A line runs the command of its key: here `cw`, Enter on the line the keys stand on.
    ask(explorer, "usage.md");
    explorer.type("jjj");
    check(explorer.view.menu.items[explorer.view.menu.current].entry == rename);
    explorer.type("<CR>");
    check(explorer.view.mode == Mode::insert && explorer.view.draft.view() == "usage.md");
    explorer.enter("guide.md");
    check(explorer.row("guide.md").renamed);

    // A new directory is one whatever its name ends in.
    ask(explorer, "assets");
    static_cast<void>(choose(explorer, new_directory));
    check(explorer.view.mode == Mode::insert);
    explorer.enter("icons");
    check(explorer.view.edits.back().kind == EditKind::create && explorer.view.edits.back().directory && explorer.view.edits.back().name.view() == "icons" && explorer.row("icons").note.view() == "new directory");

    // A row a change adds: it is renamed, or the change is dropped.
    ask(explorer, "icons");
    check(entries(explorer.view) == Entries{rename, drop_change, rule, write});
    static_cast<void>(choose(explorer, drop_change));
    check(explorer.view.edits.size() == 1 && explorer.view.mode == Mode::normal);

    // Toward the panes and the clipboard, as the keys.
    ask(explorer, "agents.md");
    check(choose(explorer, copy).kind == ActionKind::copy && explorer.view.text.view() == "/home/dev/telar/docs/agents.md" && explorer.view.yanked.size() == 1);
    ask(explorer, "assets");
    check(disabled(explorer.view) == Entries{open});
    static_cast<void>(choose(explorer, paste));
    check(explorer.view.edits.back().kind == EditKind::paste && explorer.view.edits.back().source.view() == "/home/dev/telar/docs/agents.md");
    ask(explorer, "remote.md");
    check(choose(explorer, shell_here).kind == ActionKind::split && explorer.view.text.view() == "/home/dev/telar/docs");

    // Another window, on the directory of the row.
    ask(explorer, "remote.md");
    static_cast<void>(choose(explorer, window_here));
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1 && window(explorer.view).root.view() == "/home/dev/telar/docs" && explorer.view.windows[0]->root.view() == "/home/dev/telar");
  }

  void testTheMenuActsOnTheSelectionItOpensOn() {
    using enum MenuEntry;

    Explorer explorer;

    explorer.start();
    explorer.type("l");
    explorer.click("agents.md");
    explorer.type("Vj");
    check(explorer.view.mode == Mode::visual);

    // On a row of the selection: the selection stays, and the lines count its rows.
    ask(explorer, "remote.md");
    check(explorer.view.mode == Mode::menu && explorer.view.menu.over == Mode::visual && explorer.row("agents.md").marked && explorer.row("remote.md").marked);
    check(disabled(explorer.view) == Entries{rename, paste} && menu(explorer.view, explorer.state, explorer.context()).lines[8].label.view() == "Cut (2)");
    cancel(explorer.view, explorer.state, explorer.context());
    check(explorer.view.mode == Mode::visual, "closed, it leaves the selection as it was");
    ask(explorer, "agents.md");
    static_cast<void>(choose(explorer, cut));
    check(explorer.view.edits.size() == 2 && explorer.view.mode == Mode::normal && explorer.row("agents.md").removed && explorer.row("remote.md").removed);

    // On a row outside it: that row alone.
    explorer.type("u");
    explorer.click("agents.md");
    explorer.type("Vj");
    ask(explorer, "README.md");
    check(explorer.view.menu.over == Mode::normal && explorer.selected() == "/home/dev/telar/README.md" && !explorer.row("agents.md").marked);
    static_cast<void>(choose(explorer, trash));
    check(explorer.view.edits.size() == 1 && explorer.row("README.md").removed);
  }

  // The pointer takes hold of the row named and lets go over another, or over none.
  std::size_t take(Explorer& explorer, std::string_view name) {
    return grab(explorer.view, explorer.state, explorer.context(), {.window = explorer.view.current, .row = explorer.at(name)});
  }

  void let(Explorer& explorer, const Drop& where) {
    drop(explorer.view, explorer.state, explorer.context(), where);
    explorer.answer();
  }

  void testRowsDroppedAreAChangeToWrite() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");

    // A file onto a directory moves there, when `:w` says so.
    check(take(explorer, "usage.md") == 1 && explorer.view.dragged.size() == 1);

    auto aimed = aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("assets")});

    check(aimed.count == 1 && aimed.row && *aimed.row == explorer.at("assets"), "the directory under the pointer takes it");
    let(explorer, {.window = 0, .row = explorer.at("assets")});
    check(explorer.view.dragged.empty() && explorer.view.edits.size() == 1 && explorer.view.yanked.empty(), "what `p` would put is left as it was");
    check(explorer.view.edits[0].kind == EditKind::paste && explorer.view.edits[0].paste == PasteKind::move && explorer.view.edits[0].path.view() == "/home/dev/telar/assets" && explorer.view.edits[0].source.view() == "/home/dev/telar/docs/usage.md");
    check(explorer.row("assets").expanded && explorer.names()[2] == "usage.md" && explorer.view.message.view() == "1 to move into assets · :w shows the plan");
    explorer.type("u");
    check(explorer.view.edits.empty(), "u takes a drop back");

    // Onto a file, it goes where the file is; with Alt it is copied.
    static_cast<void>(take(explorer, "usage.md"));
    aimed = aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("justfile"), .copy = true});
    check(aimed.count == 1 && !aimed.row, "the root has no row to mark");
    let(explorer, {.window = 0, .row = explorer.at("justfile"), .copy = true});
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].paste == PasteKind::copy && explorer.view.edits[0].path.view() == "/home/dev/telar");
    explorer.type("u");

    // Below the last row is the window's root.
    static_cast<void>(take(explorer, "usage.md"));
    let(explorer, {.window = 0, .row = std::numeric_limits<std::size_t>::max()});
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].path.view() == "/home/dev/telar" && explorer.view.edits[0].paste == PasteKind::move);
    explorer.type("u");

    // What is cut and then dragged somewhere moves there, and is not removed too.
    explorer.click("usage.md");
    explorer.type("dd");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::remove);
    static_cast<void>(take(explorer, "usage.md"));
    let(explorer, {.window = 0, .row = explorer.at("src")});
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::paste && explorer.view.edits[0].path.view() == "/home/dev/telar/src");
  }

  void testADropThatMovesNothingIsRefused() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");

    // Onto itself, or onto the directory it is in.
    static_cast<void>(take(explorer, "usage.md"));
    check(aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("usage.md")}).count == 0);
    let(explorer, {.window = 0, .row = explorer.at("usage.md")});
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error && explorer.view.message.view().starts_with("It is there already"));
    static_cast<void>(take(explorer, "usage.md"));

    const auto aimed = aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("docs")});

    check(aimed.count == 0 && aimed.row && *aimed.row == explorer.at("docs"));
    let(explorer, {.window = 0, .row = explorer.at("docs")});
    check(explorer.view.edits.empty() && explorer.view.history.empty(), "nothing changed, and nothing to take back");

    // A directory into itself, moved or copied.
    static_cast<void>(take(explorer, "docs"));
    let(explorer, {.window = 0, .row = explorer.at("images")});
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error);
    static_cast<void>(take(explorer, "docs"));
    let(explorer, {.window = 0, .row = explorer.at("agents.md"), .copy = true});
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error);

    // Beside itself a copy is one more, as `yy` and `p` there.
    static_cast<void>(take(explorer, "usage.md"));
    let(explorer, {.window = 0, .row = explorer.at("agents.md"), .copy = true});
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].paste == PasteKind::copy && explorer.view.edits[0].path.view() == "/home/dev/telar/docs");

    // A drag let go where nothing takes it leaves nothing behind.
    static_cast<void>(take(explorer, "usage.md"));
    release(explorer.view);
    check(explorer.view.dragged.empty() && explorer.view.edits.size() == 1);
    let(explorer, {.window = 0, .row = explorer.at("assets")});
    check(explorer.view.edits.size() == 1, "and a drop with nothing dragged drops nothing");
  }

  void testADragTakesTheSelectionAndCrossesWindows() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");
    explorer.click("agents.md");
    explorer.type("Vj");

    // A row of the selection takes the selection with it.
    check(take(explorer, "remote.md") == 2 && explorer.view.mode == Mode::visual);
    check(aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("assets")}).count == 2);
    let(explorer, {.window = 0, .row = explorer.at("assets")});
    check(explorer.view.edits.size() == 2 && explorer.view.mode == Mode::normal && explorer.view.message.view() == "2 to move into assets · :w shows the plan");
    explorer.type("u");

    // A row outside it goes alone, and the selection ends.
    explorer.click("agents.md");
    explorer.type("Vj");
    check(take(explorer, "README.md") == 1 && explorer.view.mode == Mode::normal && explorer.selected() == "/home/dev/telar/README.md");
    release(explorer.view);

    // Onto another window: its root takes the rows, and it takes the keys.
    explorer.type("<C-w>v");
    explorer.type(":");
    explorer.enter("e /home/dev/telar/assets");
    check(explorer.view.current == 1 && window(explorer.view).root.view() == "/home/dev/telar/assets");
    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("usage.md", 0)}) == 1 && explorer.view.current == 0 && explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(aim(explorer.view, explorer.state, explorer.context(), {.window = 1, .row = 0}).count == 1);
    let(explorer, {.window = 1, .row = 0});
    check(explorer.view.current == 1 && explorer.view.edits.size() == 1 && explorer.view.edits[0].path.view() == "/home/dev/telar/assets" && explorer.names() == std::vector<std::string>{"logo.svg", "usage.md"});
    explorer.type("<C-w>w");

    const auto left = look(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("remote.md") + 1});

    check(left.name.view() == "usage.md" && left.removed && left.note.view() == "moves", "the window it left shows it going");
    check(explorer.names()[2] == "usage.md" && look(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = 2}).added, "and coming, where it shows that directory too");
  }

  void testTheShortcutsOfEveryFileManager() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");
    explorer.type("<C-x>");
    check(explorer.view.edits.size() == 1 && explorer.row("usage.md").removed, "Control and x cut, where that is the system's key");
    explorer.type("<C-z>");
    check(explorer.view.edits.empty());
    explorer.type("<C-c>");
    explorer.type("gg");
    explorer.type("<C-v>");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].paste == PasteKind::copy);
    explorer.type("<C-s>");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 1, "and s writes: it shows the plan");
    explorer.type("n");
    explorer.type("<D-z>");
    check(explorer.view.edits.empty());
  }

  void testFilesDraggedInAreCopiedByThePlan() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");

    // Files of the machine the window runs on, from outside it: held as rows dragged are.
    const std::vector<std::string_view> paths{"/Users/dev/Desktop/notes.md", "/Users/dev/Desktop/shots/", "relative.txt"};

    check(bringIn(explorer.view, explorer.context(), paths) == 2 && explorer.view.dragged.size() == 2, "a path that is not absolute names nothing");
    check(explorer.view.dragged[0].machine == Explorer::machine && explorer.view.dragged[1].path.view() == "/Users/dev/Desktop/shots", "a slash at the end is no part of a name");

    const auto aimed = aim(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("assets"), .copy = true});

    check(aimed.count == 2 && aimed.copy && aimed.row && *aimed.row == explorer.at("assets"));
    drop(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("assets"), .copy = true});
    check(explorer.view.edits.size() == 2 && explorer.view.edits[0].kind == EditKind::paste && explorer.view.edits[0].paste == PasteKind::copy && explorer.view.edits[0].unidentified, "nothing is known of them but their paths");
    check(explorer.view.edits[0].source.view() == "/Users/dev/Desktop/notes.md" && explorer.view.edits[0].path.view() == "/home/dev/telar/assets" && explorer.view.edits[0].name.view() == "notes.md");

    // Their runtime is asked what each is, and the plan names what it read.
    explorer.answer();
    check(!explorer.view.edits[0].unidentified && explorer.view.edits[0].identity.inode == explorer.inspected_inode && explorer.view.edits[0].size == 7739, "then a copy names the file its runtime read");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 2 && explorer.view.plan[0].verb == PlanVerb::copy && explorer.view.plan[0].source_machine == 0 && explorer.view.plan[0].target.view() == "/home/dev/telar/assets/notes.md");
    explorer.type("n");
    explorer.type("uu");

    // On a window of another machine they are carried there, from this one.
    explorer.type(":");
    explorer.enter("vs box:~");
    check(bringIn(explorer.view, explorer.context(Explorer::box), paths) == 2 && explorer.view.dragged[0].machine == Explorer::machine, "they are of the machine the window runs on, whatever window takes them");
    drop(explorer.view, explorer.remote, explorer.context(Explorer::box), {.window = 1, .row = 0, .copy = true});
    check(explorer.view.edits.size() == 2 && explorer.view.edits[0].machine == Explorer::box && explorer.view.edits[0].source_machine == Explorer::machine && explorer.view.edits[0].path.view() == "/home/ops/logs");
    explorer.answer();
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan[0].source_machine == Explorer::machine && explorer.view.plan[0].machine == Explorer::box, "the plan carries them between the two");
  }

  const telar::testing::Case case_menu{"pointer.the_menu_of_a_row_lists_what_applies_to_it", testTheMenuOfARowListsWhatAppliesToIt};
  const telar::testing::Case case_menu_keys{"pointer.the_keys_move_in_the_menu_and_a_line_runs_what_its_key_runs", testTheKeysMoveInTheMenuAndALineRunsWhatItsKeyRuns};
  const telar::testing::Case case_menu_selection{"pointer.the_menu_acts_on_the_selection_it_opens_on", testTheMenuActsOnTheSelectionItOpensOn};
  const telar::testing::Case case_drop{"pointer.rows_dropped_are_a_change_to_write", testRowsDroppedAreAChangeToWrite};
  const telar::testing::Case case_refused{"pointer.a_drop_that_moves_nothing_is_refused", testADropThatMovesNothingIsRefused};
  const telar::testing::Case case_selection{"pointer.a_drag_takes_the_selection_and_crosses_windows", testADragTakesTheSelectionAndCrossesWindows};
  const telar::testing::Case case_in{"pointer.files_dragged_in_are_copied_by_the_plan", testFilesDraggedInAreCopiedByThePlan};
  const telar::testing::Case case_shortcuts{"pointer.the_shortcuts_of_every_file_manager", testTheShortcutsOfEveryFileManager};

}
