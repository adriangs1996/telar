#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  using Names = std::vector<std::string>;

  void testItOpensAtTheFocusedPane() {
    Explorer explorer;

    explorer.start();

    const auto& shown = window(explorer.view);

    check(shown.root.view() == "/home/dev/telar" && shown.follow, "rooted at the workspace, following the focused pane");
    check(explorer.names() == Names{"assets/", "docs/", "src/", "justfile", "README.md"}, "dotfiles and what git ignores left out");
    check(explorer.selected() == "/home/dev/telar/docs", "the selection on the pane's directory, which stays folded");
    check(shown.hidden_entries == 2 && shown.ignored_entries == 1, "and how many entries of the root it leaves out");
    check(explorer.row("docs").pane_count == 1 && explorer.row("docs").panes[0] == 3 && !explorer.row("docs").expanded, "the directory says which pane is in it");
    check(shown.bytes == 6800000 + 3800000 + 120000 + 4096 + 21000000000ULL + 5 + 8300 + 5500, "what the root holds counts what is not listed too");

    // Another pane takes the focus: the window goes with it.
    explorer.focused = 12;
    explorer.answer();
    check(explorer.selected() == "/home/dev/telar/src" && explorer.row("src").pane_count == 0, "an editor is in the directory, with no shell there to mark");
    check(!follow(explorer.view, explorer.context(), Explorer::machine), "a pane that did not move leaves the window where it is");
  }

  void testTheKeysMoveAsNeovims() {
    Explorer explorer;

    explorer.start();

    // The preview of the row a key moved to arrives: what shows beside the rows reads it, and the
    // rows are not built again for it.
    const auto built = explorer.state.revision;
    const auto previews = explorer.state.previews;

    explorer.type("j");
    check(explorer.state.previews == previews + 1 && explorer.state.revision == built && explorer.view.built == built && explorer.view.previewed == explorer.state.previews);
    explorer.type("k");
    explorer.type("l");
    check(explorer.row("docs").expanded, "l unfolds the directory of the selection");
    explorer.type("gg");
    check(explorer.selected() == "/home/dev/telar/assets");
    explorer.type("3j");
    check(explorer.selected() == "/home/dev/telar/docs/agents.md", "a count before the motion");
    explorer.type("G");
    check(explorer.selected() == "/home/dev/telar/README.md");
    explorer.type("2G");
    check(explorer.selected() == "/home/dev/telar/docs", "a count before G names the row");
    explorer.type("99k");
    check(explorer.selected() == "/home/dev/telar/assets", "a motion stops at the end of the listing");

    // h folds, or goes to the directory that holds the row; l unfolds, then moves into it.
    explorer.type("j");
    explorer.type("h");
    check(!explorer.row("docs").expanded && explorer.names() == Names{"assets/", "docs/", "src/", "justfile", "README.md"});
    explorer.type("l");
    check(explorer.row("docs").expanded);
    explorer.type("l");
    check(explorer.selected() == "/home/dev/telar/docs/images");
    explorer.type("jh");
    check(explorer.selected() == "/home/dev/telar/docs", "h on a file goes to its directory");
    explorer.type("zM");
    check(explorer.names().size() == 5);
    explorer.type("zR");
    check(explorer.names().size() == 11 && explorer.row("images").directory && !explorer.row("images").expanded, "zR unfolds every directory that shows, not what they hold");

    // The changes of git: usage.md is modified, remote.md is staged.
    explorer.type("gg]c");
    check(explorer.selected() == "/home/dev/telar/docs", "a directory with changes below it counts");
    explorer.type("]c]c");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
  }

  void testRootsMarksAndJumps() {
    Explorer explorer;

    explorer.start();
    explorer.type("lgg3j");
    explorer.type("mA");
    explorer.type("gg<CR>");
    check(window(explorer.view).root.view() == "/home/dev/telar/assets" && !window(explorer.view).follow, "Enter on a directory roots the window there, and it stops following");
    check(explorer.names() == Names{"logo.svg"});
    explorer.type("-");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/assets", "- goes up, with the directory it came from selected");
    explorer.type("-");
    check(window(explorer.view).root.view() == "/home/dev" && explorer.names() == Names{"telar/", "notes.txt"});
    explorer.type("<C-o>");
    check(window(explorer.view).root.view() == "/home/dev/telar", "<C-o> goes back in the jumps");
    explorer.type("<C-o><C-o>");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/assets");
    explorer.type("<C-i>");
    check(window(explorer.view).root.view() == "/home/dev/telar/assets", "<C-i> comes forward");
    explorer.type("'A");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/docs/agents.md", "a mark keeps the root and the selection");
    check(explorer.row("agents.md").marks.view() == "'A");
    explorer.type("'z");
    check(explorer.view.tone == Tone::error && explorer.view.message.view().starts_with("E20"), "a mark not set says so, as Neovim does");
    explorer.type("~");
    check(window(explorer.view).root.view() == "/home/dev");
    explorer.type("_");
    check(window(explorer.view).root.view() == "/home/dev/telar");
    explorer.type("gp");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && window(explorer.view).follow, "gp follows the pane again, rooted at its directory");
  }

  void testWhatIsListedAndInWhichOrder() {
    Explorer explorer;

    explorer.start();
    explorer.type("zM");
    explorer.type("g.");
    check(explorer.names() == Names{".github/", "assets/", "docs/", "src/", ".gitignore", "justfile", "README.md"}, "g. lists the dotfiles");
    explorer.type("gi");
    check(explorer.names()[3] == "out/" && explorer.row("out").ignored, "gi lists what git ignores, marked so");
    check(window(explorer.view).hidden_entries == 0 && window(explorer.view).ignored_entries == 0);
    explorer.type("S");
    check(explorer.names().front() == "out/" && explorer.names()[1] == "assets/", "S sorts by size, the largest first");
    check(explorer.row("out").share == 1000 && explorer.row("docs").share < 1000, "each row's share of the largest beside it");
    explorer.type("S");
    check(explorer.names().front() == "README.md", "then by time, the newest first");
    explorer.type("S");
    check(explorer.names().front() == ".github/");

    // A filter narrows the listing, and keeps an unfolded directory that holds a match.
    explorer.type("g.gi");
    explorer.type("l/");
    typed(explorer.view, explorer.state, explorer.context(), "USAGE");
    explorer.answer();
    check(explorer.names() == Names{"docs/", "usage.md"}, "without regard to case");
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.answer();
    check(explorer.names().size() == 9);

    // The other lenses.
    explorer.type("gt");
    check(window(explorer.view).lens == Lens::changes && explorer.names() == Names{"Staged", "docs/remote.md", "Unstaged", "docs/usage.md", "Untracked", ".github/"}, "what git says, in three groups");
    check(explorer.row("usage.md").lines_added == 12 && explorer.row("usage.md").lines_removed == 7);
    explorer.type("gt");
    check(window(explorer.view).lens == Lens::panes && explorer.names().size() == 3, "the panes of the tab");
    explorer.type("1gt");
    check(window(explorer.view).lens == Lens::tree);
  }

  void testEnterHandsAFileToTheFocusedPane() {
    Explorer explorer;

    explorer.start();
    // The window stays where it is while the test gives the focus to one pane and another.
    explorer.type("F");
    check(!window(explorer.view).follow);
    explorer.type("l4j");

    auto action = explorer.type("<CR>");

    check(action.kind == ActionKind::insert && action.pane == 13 && explorer.view.text.view() == "usage.md ", "at a shell, the path from the shell's directory");

    explorer.focused = 11;
    action = explorer.type("<CR>");
    check(action.kind == ActionKind::mention && action.pane == 11 && explorer.view.text.view() == "@docs/usage.md ", "to an agent, a mention");

    explorer.focused = 12;
    action = explorer.type("<CR>");
    check(action.kind == ActionKind::open && explorer.view.paths.size() == 1 && explorer.view.paths[0].view() == "/home/dev/telar/docs/usage.md", "in an editor, the file opened");

    // Several rows at once, and the commands that name their pane.
    explorer.focused = 13;
    explorer.type("kV");
    action = explorer.type("j<CR>");
    check(action.kind == ActionKind::insert && explorer.view.text.view() == "remote.md usage.md " && explorer.view.mode == Mode::normal, "a selection is inserted whole, and ends");
    action = explorer.type("@");
    check(action.kind == ActionKind::mention && action.pane == 11 && explorer.view.text.view() == "@docs/usage.md ");
    action = explorer.type("gf");
    check(action.kind == ActionKind::open);
    action = explorer.type("cd");
    check(action.kind == ActionKind::change_directory && action.pane == 13 && explorer.view.text.view() == "/home/dev/telar/docs", "cd goes to the directory a file is in");
    action = explorer.type("s");
    check(action.kind == ActionKind::split && explorer.view.text.view() == "/home/dev/telar/docs");
    action = explorer.type("yy");
    check(action.kind == ActionKind::copy && explorer.view.text.view() == "/home/dev/telar/docs/usage.md");
    action = explorer.type("yn");
    check(action.kind == ActionKind::copy && explorer.view.text.view() == "usage.md");
    check(explorer.type("q").kind == ActionKind::close);
  }

  void testWindowsSplitAndClose() {
    Explorer explorer;

    explorer.start();
    explorer.type("<C-w>v");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1 && explorer.view.side_by_side, "the new window takes the keys");
    check(!window(explorer.view).follow && window(explorer.view).root.view() == "/home/dev/telar", "on the same directory, no longer following");
    explorer.type(":");
    explorer.enter("e ~/telar/docs");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && explorer.view.windows[0]->root.view() == "/home/dev/telar", ":e goes somewhere else in one window alone");
    explorer.type("<C-w>w");
    check(explorer.view.current == 0);
    explorer.type("<C-w>s<C-w>v");
    check(explorer.view.windows.size() == 3 && explorer.view.message.view() == "Three windows at most");
    explorer.type("<C-w>o");
    check(explorer.view.windows.size() == 1 && explorer.view.current == 0);
    explorer.type(":");
    check(explorer.enter("vs ../..").kind == ActionKind::none && explorer.view.windows.size() == 2 && window(explorer.view).root.view() == "/home", ":vs takes a path, from the window's root");
    explorer.type(":");
    check(explorer.enter("q").kind == ActionKind::none && explorer.view.windows.size() == 1, ":q closes a window while there is another");
    explorer.type(":");
    check(explorer.enter("q").kind == ActionKind::close, "and the explorer with the last one");
    explorer.type(":");
    explorer.enter("frobnicate");
    check(explorer.view.message.view() == "E492: Not an editor command: frobnicate");
  }

  const telar::testing::Case case_opens{"view.it_opens_at_the_focused_pane", testItOpensAtTheFocusedPane};
  const telar::testing::Case case_moves{"view.the_keys_move_as_neovims", testTheKeysMoveAsNeovims};
  const telar::testing::Case case_roots{"view.roots_marks_and_jumps", testRootsMarksAndJumps};
  const telar::testing::Case case_listed{"view.what_is_listed_and_in_which_order", testWhatIsListedAndInWhichOrder};
  const telar::testing::Case case_hands{"view.enter_hands_a_file_to_the_focused_pane", testEnterHandsAFileToTheFocusedPane};
  const telar::testing::Case case_windows{"view.windows_split_and_close", testWindowsSplitAndClose};

}
