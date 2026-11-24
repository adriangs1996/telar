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

    explorer.start(true);

    const auto& shown = window(explorer.view);

    check(shown.root.view() == "/home/dev/telar" && shown.follow, "rooted at the workspace, following the focused pane");
    check(explorer.names() == Names{"assets/", "docs/", "images/", "agents.md", "remote.md", "usage.md", "src/", "justfile", "README.md"}, "the pane's directory unfolded; dotfiles and what git ignores left out");
    check(explorer.selected() == "/home/dev/telar/docs" && explorer.row("docs").expanded, "and the selection on it");
    check(shown.hidden_entries == 2 && shown.ignored_entries == 1, "and how many entries of the root it leaves out");
    check(explorer.leftOut() == "2 dotfiles (g.) · 1 ignored by git (gi) not listed here", "which the last row of the tree says, with the keys that list them");
    check(status(explorer.view, explorer.state, explorer.context(), 0).count == 9, "a row no key selects");
    check(explorer.row("docs").pane_count == 1 && explorer.row("docs").panes[0] == 3, "the directory says which pane is in it");
    check(shown.bytes == 6800000 + 3800000 + 120000 + 4096 + 21000000000ULL + 5 + 8300 + 5500, "what the root holds counts what is not listed too");

    // Another pane takes the focus: the window goes with it. An editor on no file is in a
    // directory, which is chosen and stays folded: it is the file it edits that would show.
    explorer.focused = 12;
    explorer.answer();
    check(explorer.selected() == "/home/dev/telar/src" && !explorer.row("src").expanded && explorer.row("src").pane_count == 0, "an editor is in the directory, with no shell there to mark");
    check(!follow(explorer.view, explorer.context(), Explorer::machine), "a pane that did not move leaves the window where it is");

    // The editor goes to a file: the window chooses that file, in its directory unfolded.
    explorer.panes[1].buffer = "/home/dev/telar/docs/images/window.png";
    explorer.answer();
    explorer.answer();
    check(explorer.selected() == "/home/dev/telar/docs/images/window.png" && explorer.row("images").expanded && explorer.row("window.png").selected, "with an editor it is the file being edited that is chosen");
    check(!follow(explorer.view, explorer.context(), Explorer::machine));
    // To another file: the window follows the buffer, though the pane did not move.
    explorer.panes[1].buffer = "/home/dev/telar/src/main.cpp";
    // The window follows once the scene is observed, and then asks for what it unfolded.
    explorer.answer();
    explorer.answer();
    check(explorer.selected() == "/home/dev/telar/src/main.cpp" && explorer.row("main.cpp").selected, "and it follows the editor from one file to the next");
    // A file outside the root is not shown: the window stays at its scope.
    explorer.panes[1].buffer = "/etc/hosts";
    explorer.answer();
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/src/main.cpp");
  }

  void testTheKeysMoveAsNeovims() {
    Explorer explorer;

    explorer.start();

    // The preview of the row a key moved to arrives: what shows beside the rows reads it, and the
    // rows are not built again for it.
    const auto built = explorer.state.revision;
    const auto previews = explorer.state.previews;

    explorer.type("j");
    check(explorer.state.previews == previews + 1 && explorer.state.revision == built && window(explorer.view).built == built && window(explorer.view).previewed == explorer.state.previews);
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
    check(explorer.names().size() == 12 && explorer.row("images").expanded && explorer.row("window.png").depth == 2, "zR unfolds every directory, and what each holds as its listing comes");
    check(!window(explorer.view).unfolding, "and is done once nothing is left folded");

    // zo unfolds and zc folds; zc on what is in a directory folds that one, and selects it.
    explorer.type("zM");
    explorer.type("ggjzo");
    check(explorer.row("docs").expanded && explorer.selected() == "/home/dev/telar/docs");
    explorer.type("zo");
    check(explorer.row("docs").expanded, "zo on one unfolded leaves it so");
    explorer.type("jjzc");
    check(!explorer.row("docs").expanded && explorer.selected() == "/home/dev/telar/docs");

    // <C-n> and <C-p> move as j and k; Backspace goes up as - does.
    explorer.type("gg<C-n><C-n>");
    check(explorer.selected() == "/home/dev/telar/src");
    explorer.type("<C-p>");
    check(explorer.selected() == "/home/dev/telar/docs");
  }

  void testTheNextChangeUnfoldsWhatHidesIt() {
    Explorer explorer;

    // The changes of git: remote.md is staged and usage.md modified, both in a folded directory;
    // .github/ is not listed, and out/ is ignored.
    explorer.start();
    explorer.type("zMgg");
    check(!explorer.row("docs").expanded);
    explorer.type("]c");
    check(explorer.selected() == "/home/dev/telar/docs/remote.md" && explorer.row("docs").expanded, "]c goes to the next changed path in the tree's order, unfolding what hides it");
    explorer.type("]c");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    explorer.type("]c");
    check(explorer.selected() == "/home/dev/telar/docs/remote.md", "and around past the last");
    explorer.type("[c");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md", "[c the other way");

    // From another lens it goes to the tree.
    explorer.type("2gt");
    explorer.type("]c");
    check(window(explorer.view).lens == Lens::tree && explorer.selected().starts_with("/home/dev/telar/docs/"));

    // With the dotfiles listed, the directory git does not track is one of them.
    explorer.type("g.gg");
    explorer.type("[c");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md", "before the first, the last");
    explorer.type("]c");
    check(explorer.selected() == "/home/dev/telar/.github", "a directory git does not track is a change of its own, once the window lists it");

    Explorer clean;

    clean.changes.clear();
    clean.start();
    clean.type("]c");
    check(clean.view.tone == Tone::error && clean.view.message.view() == "Nothing changed below this directory");
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
    check(explorer.leftOut() == "1 ignored by git (gi) not listed here");
    explorer.type("gi");
    check(explorer.names()[3] == "out/" && explorer.row("out").ignored, "gi lists what git ignores, marked so");
    check(explorer.leftOut().empty(), "with nothing left out the tree ends at its last entry");
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
    check(window(explorer.view).lens == Lens::touched, "who touched what, which a case of its own looks at");
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

  void testAWindowIsReachedByItsSide() {
    Explorer explorer;

    explorer.start();
    explorer.type("<C-w>l");
    check(explorer.view.current == 0 && explorer.view.message.view() == "No window that way");
    explorer.type("<C-w>v");
    check(explorer.view.current == 1 && explorer.view.side_by_side);
    explorer.type("<C-w>l");
    check(explorer.view.current == 1 && explorer.view.message.view() == "No window that way", "past the last there is none: it does not go around");
    explorer.type("<C-w>h");
    check(explorer.view.current == 0 && explorer.view.message.view().empty());
    explorer.type("<C-w>j");
    check(explorer.view.current == 0 && explorer.view.message.view() == "No window that way", "side by side, none is below");
    explorer.type("<C-w>l");
    check(explorer.view.current == 1);

    // One below the other.
    explorer.type("<C-w>o<C-w>s");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1 && !explorer.view.side_by_side);
    explorer.type("<C-w>h");
    check(explorer.view.current == 1 && explorer.view.message.view() == "No window that way");
    explorer.type("<C-w>k");
    check(explorer.view.current == 0);
    explorer.type("<C-w>j");
    check(explorer.view.current == 1);

    // Alt with w starts the same sequences.
    explorer.type("<M-w>k");
    check(explorer.view.current == 0);
  }

  void testTheCommandLineTakesTheCommandsOfTheDesign() {
    Explorer explorer;

    explorer.start();

    // :cd is the shell's cd: the window stays where it is.
    explorer.type(":");

    auto action = explorer.enter("cd docs/images");

    check(action.kind == ActionKind::change_directory && action.pane == 13 && explorer.view.text.view() == "/home/dev/telar/docs/images");
    check(window(explorer.view).root.view() == "/home/dev/telar", "the window is not taken there");
    explorer.type(":");
    action = explorer.enter("cd");
    check(action.kind == ActionKind::change_directory && explorer.view.text.view() == "/home/dev/telar", "with no path, to the window's root");
    explorer.type(":");
    check(explorer.enter("cd box:~/logs").kind == ActionKind::none && explorer.view.message.view() == "That directory is on box and the panes are of macbook");
    explorer.focused = 11;
    explorer.type(":");
    check(explorer.enter("cd docs").kind == ActionKind::none && explorer.view.message.view() == "cd is for a shell's pane; s opens one here");
    explorer.focused = 13;

    // A number is a row, as a count before G.
    explorer.type(":");
    explorer.enter("4");
    check(explorer.selected() == "/home/dev/telar/justfile");
    explorer.type(":");
    explorer.enter("99");
    check(explorer.selected() == "/home/dev/telar/README.md", "past the last, the last");

    // :wq shows the plan, as :w does; and :wa! overwrites, as :w! does.
    explorer.type("dd:");
    explorer.enter("wq");
    check(explorer.view.mode == Mode::plan && !explorer.view.overwrite);
    explorer.type("n:");
    explorer.enter("wa!");
    check(explorer.view.mode == Mode::plan && explorer.view.overwrite);
    explorer.type("nu");

    // :scope names where a window that follows roots itself.
    explorer.type(":");
    explorer.enter("scope pane");
    check(window(explorer.view).scope == Scope::pane && window(explorer.view).follow && window(explorer.view).root.view() == "/home/dev/telar/docs");
    explorer.type(":");
    explorer.enter("scope nowhere");
    check(explorer.view.tone == Tone::error && explorer.view.message.view() == "scope pane, workspace or machine");
    explorer.type(":");
    explorer.enter("scope workspace");
    check(window(explorer.view).scope == Scope::workspace && window(explorer.view).root.view() == "/home/dev/telar");

    // <Tab> completes the name of a command, or lists the ones that start so.
    explorer.type(":");
    complete(explorer.view, explorer.state, explorer.context(), "sc");
    check(explorer.view.completion.view() == "scope ", "the one name, and a space after it");

    const auto completed = explorer.view.completed;

    complete(explorer.view, explorer.state, explorer.context(), "w");
    check(explorer.view.completed == completed && explorer.view.message.view() == "w  w!  wa  wq  write", "several leave the line as it is, and are listed");
    complete(explorer.view, explorer.state, explorer.context(), "zz");
    check(explorer.view.tone == Tone::error && explorer.view.message.view() == "No command starts with that");
  }

  void testTheLastActionIsRepeated() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");

    auto action = explorer.type("yn");

    check(action.kind == ActionKind::copy && explorer.view.text.view() == "usage.md");
    explorer.type("k");
    action = explorer.type(".");
    check(action.kind == ActionKind::copy && explorer.view.text.view() == "remote.md", ". copies the name of another row");
    explorer.type("yr");
    explorer.type("j");
    action = explorer.type(".");
    check(action.kind == ActionKind::copy && explorer.view.text.view() == "usage.md", "and its path from the pane, in the pane's directory");
    explorer.type("cd");
    explorer.type("gg");
    action = explorer.type(".");
    check(action.kind == ActionKind::change_directory && explorer.view.text.view() == "/home/dev/telar/assets");
    explorer.type("s");
    explorer.type("j");
    action = explorer.type(".");
    check(action.kind == ActionKind::split && explorer.view.text.view() == "/home/dev/telar/docs");
    explorer.type("4jgX");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::restore);
    explorer.type("k.");
    check(explorer.view.edits.size() == 1 && explorer.view.message.view() == "Nothing unstaged to discard here", ". discards again, where there is something to");
  }

  void testAMarkIsOfTheRowItIsSetOn() {
    Explorer explorer;

    explorer.start();
    explorer.type("ma");
    check(explorer.view.message.view() == "mark 'a → /home/dev/telar/docs" && explorer.row("docs").marks.view() == "'a");
    explorer.type("jjmb");
    check(explorer.view.message.view() == "mark 'b → /home/dev/telar/justfile" && explorer.row("justfile").marks.view() == "'b");

    const auto shown = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(shown.facts[shown.fact_count - 1].label == "Marks" && shown.facts[shown.fact_count - 1].value.view() == "'b", "the preview says the marks of what it shows");
    explorer.type("gg'a");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && explorer.names().size() == 4, "a directory that was marked is the root its mark goes to");
    explorer.type("`b");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/justfile", "a file is selected where the window listed it; either quote jumps");
  }

  void testADiffUnfoldsInTheChanges() {
    Explorer explorer;

    // usage.md is the third of the fixture's changes: here the index holds all of its change.
    explorer.changes[2] = {.path = "docs/usage.md", .staged = FileState::modified, .added = 1};
    explorer.start();
    explorer.type("2gt");
    check(explorer.names() == Names{"Staged", "docs/remote.md", "docs/usage.md", "Untracked", ".github/"});
    explorer.type("j=");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(explorer.names() == Names{"Staged", "docs/remote.md", "docs/usage.md", "@@ -1,2 +1,2 @@", "-old", "+new", " context", "Untracked", ".github/"}, "= unfolds the diff below the row of the lens too");
    check(window(explorer.view).rows[3].kind == RowKind::diff && window(explorer.view).rows[3].depth == 1 && window(explorer.view).rows[4].tone == DiffTone::removed);
    explorer.type("j");
    check(explorer.selected() == "/home/dev/telar/.github", "the lines of a diff are no rows to select");
    explorer.type("k=");
    check(explorer.names().size() == 5, "and folds it again");

    // A file the index and the working tree both changed shows it once, in the second group.
    Explorer both;

    both.changes[2].staged = FileState::modified;
    both.start();
    both.type("2gt");
    check(both.names() == Names{"Staged", "docs/remote.md", "docs/usage.md", "Unstaged", "docs/usage.md", "Untracked", ".github/"});
    both.type("jj=");
    check(both.names() == Names{"Staged", "docs/remote.md", "docs/usage.md", "Unstaged", "docs/usage.md", "@@ -1,2 +1,2 @@", "-old", "+new", " context", "Untracked", ".github/"});
  }

  const telar::testing::Case case_opens{"view.it_opens_at_the_focused_pane", testItOpensAtTheFocusedPane};
  const telar::testing::Case case_next_change{"view.the_next_change_unfolds_what_hides_it", testTheNextChangeUnfoldsWhatHidesIt};
  const telar::testing::Case case_sides{"view.a_window_is_reached_by_its_side", testAWindowIsReachedByItsSide};
  const telar::testing::Case case_commands{"view.the_command_line_takes_the_commands_of_the_design", testTheCommandLineTakesTheCommandsOfTheDesign};
  const telar::testing::Case case_repeats{"view.the_last_action_is_repeated", testTheLastActionIsRepeated};
  const telar::testing::Case case_marks_row{"view.a_mark_is_of_the_row_it_is_set_on", testAMarkIsOfTheRowItIsSetOn};
  const telar::testing::Case case_diffs{"view.a_diff_unfolds_in_the_changes", testADiffUnfoldsInTheChanges};
  const telar::testing::Case case_moves{"view.the_keys_move_as_neovims", testTheKeysMoveAsNeovims};
  const telar::testing::Case case_roots{"view.roots_marks_and_jumps", testRootsMarksAndJumps};
  const telar::testing::Case case_listed{"view.what_is_listed_and_in_which_order", testWhatIsListedAndInWhichOrder};
  const telar::testing::Case case_hands{"view.enter_hands_a_file_to_the_focused_pane", testEnterHandsAFileToTheFocusedPane};
  const telar::testing::Case case_windows{"view.windows_split_and_close", testWindowsSplitAndClose};

}
