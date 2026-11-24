#include "explorer_fixture.hpp"

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;
  using Names = std::vector<std::string>;

  Action run(Explorer& explorer, std::string_view command) {
    explorer.type(":");
    return explorer.enter(command);
  }

  bool hinted(const Explorer& explorer, std::string_view keys, std::string_view label) {
    const auto shown = hints(explorer.view, explorer.cache(explorer.here()), explorer.context());

    return std::ranges::any_of(shown.items.view().first(shown.count), [&](const Hint& hint) {
      return hint.keys.view() == keys && hint.label.view() == label;
    });
  }

  void testEditTakesAFileToItsDirectory() {
    Explorer explorer;

    explorer.start();

    // A file the listings know is chosen where it is: below the root the window stays there.
    run(explorer, "e README.md");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/README.md" && !window(explorer.view).follow, ":e FILE chooses the file, and the window stops following");
    // One no listing knows becomes the root until its machine says it is a file.
    run(explorer, "e docs/usage.md");
    check(window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/docs/usage.md" && explorer.row("docs").expanded, "one below a folded directory is chosen in the tree, its directory unfolded");
    run(explorer, "e /home/dev/notes.txt");
    check(window(explorer.view).root.view() == "/home/dev" && explorer.selected() == "/home/dev/notes.txt" && explorer.view.tone != Tone::error, "one outside the root is chosen in its own directory");
    check(!window(explorer.view).opened);

    // A directory is where the window goes, as before.
    run(explorer, "e telar/docs");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && !window(explorer.view).opened);

    // A path that is nothing leaves the window where it was, and says so.
    explorer.gone.insert("/home/dev/telar/docs/nothing.md");
    run(explorer, "e nothing.md");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && explorer.view.tone == Tone::error && explorer.view.message.view() == "E: nothing is at /home/dev/telar/docs/nothing.md on macbook", "a path that is not there is an error, and the window does not move");
    check(!window(explorer.view).opened && explorer.names() == Names{"images/", "agents.md", "remote.md", "usage.md"});

    // On another machine: a file is chosen there, and a path that is nothing sends the window back.
    run(explorer, "e box:~/deploy.sh");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/home/ops" && explorer.selected() == "/home/ops/deploy.sh", "a file of another machine is chosen in its directory there");
    explorer.gone.insert("/home/ops/missing");
    run(explorer, "e macbook:/home/dev/telar");
    run(explorer, "e box:~/missing");
    explorer.answer();
    check(explorer.here() == Explorer::machine && window(explorer.view).root.view() == "/home/dev/telar" && explorer.view.message.view() == "E: nothing is at /home/ops/missing on box", "and from a path that is nothing there the window returns to its machine");
  }

  void testThePlanTakesAYesOrANoAndNothingElse() {
    Explorer explorer;

    explorer.start();
    explorer.type("jdd");
    run(explorer, "w");
    check(explorer.view.mode == Mode::plan);
    check(explorer.type("<CR>").kind == ActionKind::none && explorer.type("x").kind == ActionKind::none && explorer.type("j").kind == ActionKind::none && explorer.view.mode == Mode::plan && !explorer.view.plan.empty(), "a key that is no answer leaves the plan as it is");
    explorer.type("N");
    check(explorer.view.mode == Mode::normal && explorer.view.edits.size() == 1 && explorer.view.message.view() == "Plan cancelled · the changes are still pending");
    run(explorer, "w");
    explorer.type("q");
    check(explorer.view.mode == Mode::normal && explorer.view.open, "q leaves the plan, not the explorer");
    run(explorer, "w");
    check(explorer.type("Y").kind == ActionKind::apply && explorer.view.writing, "Y applies it as y does");
  }

  void testAPasteGoesNowhereItAlreadyIs() {
    Explorer explorer;

    explorer.start();
    explorer.type("G");
    check(explorer.selected() == "/home/dev/telar/README.md");
    // Cut and put in the directory it is in: nothing to move.
    explorer.type("ddu");
    explorer.view.yank = PasteKind::move;
    explorer.type("p");
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error && explorer.view.message.view() == "It is there already, or a directory would go into itself: nothing put", "a move to where it is does nothing");
    // A directory does not go into itself, moved or copied.
    explorer.type("ggjyyl");
    check(explorer.selected() == "/home/dev/telar/docs" && explorer.row("docs").expanded);
    explorer.type("p");
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error, "nor does a directory go into itself");
    check(explorer.view.history.empty(), "and nothing is left for u to take back");
    // A copy beside itself is a copy.
    explorer.type("hGyyp");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::paste);
    explorer.type("u");

    // The other lenses have no directory to put it in.
    explorer.type("2gtp");
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error && explorer.view.message.view() == "p puts in the tree: gt goes there");
  }

  void testAPathCopiedLeavesWhatWasYanked() {
    Explorer explorer;

    explorer.start();
    explorer.type("Gyy");
    check(explorer.view.yanked.size() == 1 && explorer.view.yanked[0].path.view() == "/home/dev/telar/README.md");
    check(hinted(explorer, "p", "paste 1 (copy)"), "the hints say what p would put, and how");
    explorer.type("k");

    auto action = explorer.type("yn");

    check(action.kind == ActionKind::copy && explorer.view.text.view() == "justfile");
    check(explorer.view.yanked.size() == 1 && explorer.view.yanked[0].path.view() == "/home/dev/telar/README.md", "yn copies a name and leaves what yy took");
    action = explorer.type("yr");
    check(action.kind == ActionKind::copy && explorer.view.yanked[0].path.view() == "/home/dev/telar/README.md", "and so does yr");
    explorer.type("dd");
    check(hinted(explorer, "p", "paste 1 (move)"));
  }

  void testACommitTakesItsMessageWithoutItsQuotes() {
    Explorer explorer;

    explorer.start();
    check(run(explorer, "commit \"Describe the usage\"").kind == ActionKind::commit && explorer.view.text.view() == "Describe the usage", "quotes around the message are a shell's habit, and no part of it");
    check(run(explorer, "commit 'One more'").kind == ActionKind::commit && explorer.view.text.view() == "One more");
    check(run(explorer, "commit Say \"why\"").kind == ActionKind::commit && explorer.view.text.view() == "Say \"why\"", "the ones inside it stay");
    check(run(explorer, "commit \"\"").kind == ActionKind::none && explorer.view.tone == Tone::error, "and an empty message is none");
  }

  void testTheKeysSayWhatTheyDid() {
    Explorer explorer;

    explorer.start();
    explorer.type("S");
    check(explorer.view.message.view() == "sorted by size, the largest first");
    explorer.type("SS");
    check(explorer.view.message.view() == "sorted by name, directories first");
    explorer.type("g.");
    check(explorer.view.message.view() == "dotfiles listed");
    explorer.type("g.gi");
    check(explorer.view.message.view() == "what git ignores listed, dimmed");
    explorer.type("gizR");
    check(explorer.view.message.view() == "all unfolded");
    explorer.type("zM");
    check(explorer.view.message.view() == "all folded" && explorer.names() == Names{"assets/", "docs/", "src/", "justfile", "README.md"});
    explorer.type("F");
    check(explorer.view.message.view() == "fixed here" && !window(explorer.view).follow);
    explorer.type("F");
    check(explorer.view.message.view() == "following pane 3" && window(explorer.view).follow);
    run(explorer, "follow");
    check(!window(explorer.view).follow, ":follow turns it off as it turns it on");
    run(explorer, "follow");
    check(window(explorer.view).follow);

    // Keys that name nothing say so, once they can start nothing.
    explorer.type("Z");
    check(explorer.view.tone == Tone::error && explorer.view.message.view() == "Z does nothing here · ? shows the keys");
    explorer.type("j");
    check(explorer.view.message.view().empty());
    explorer.type("g");
    check(explorer.view.message.view().empty(), "the start of a sequence waits for its end");
    explorer.type("Q");
    check(explorer.view.tone == Tone::error && explorer.view.message.view() == "gQ does nothing here · ? shows the keys");
  }

  void testASelectionTakesTheKeysOfNormalMode() {
    Explorer explorer;

    explorer.start();
    explorer.type("Vj");
    check(explorer.view.mode == Mode::visual);
    explorer.type("n");
    check(explorer.view.mode == Mode::visual, "a key that only moves keeps the selection");
    explorer.type(":");
    check(explorer.view.mode == Mode::command, "the command line opens from a selection");
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("Vj?");
    check(explorer.view.mode == Mode::help);
    explorer.type("<Esc>");
    explorer.type("Vjgt");
    check(explorer.view.mode == Mode::normal && window(explorer.view).lens == Lens::changes, "a command of normal mode runs, and the selection ends");
    explorer.type("1gtVjS");
    check(explorer.view.mode == Mode::normal && window(explorer.view).sort == Sort::size);
    explorer.type("SSVq");
    check(explorer.view.mode == Mode::normal && explorer.view.open, "q leaves the selection, not the explorer");
  }

  void testTheStatusLineSaysWhichWindowAndWhichMachine() {
    Explorer explorer;

    explorer.start();
    run(explorer, "vs box:~");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1);

    const auto first = status(explorer.view, explorer.state, explorer.context(Explorer::machine), 0);
    const auto second = status(explorer.view, explorer.remote, explorer.context(Explorer::box), 1);

    check(!first.current && std::string_view{first.mode} == "1" && first.machine.view().empty(), "a window without the keys says which it is");
    check(second.current && std::string_view{second.mode} == "NORMAL" && second.machine.view() == "box:" && second.root.view() == "~", "and one on another machine names it before its root");
  }

  void testAMachineKeepsWhatWasUnfoldedOnIt() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");
    check(explorer.row("docs").expanded);
    explorer.type("gm");
    check(explorer.here() == Explorer::box);
    explorer.type("l");
    check(explorer.row("logs").expanded && explorer.names() == Names{"logs/", "app.log", "db.log", "site/", "deploy.sh"});
    explorer.type("gm");
    check(explorer.here() == Explorer::machine && explorer.row("docs").expanded, "back on a machine, what was unfolded there is unfolded");
    explorer.type("gm");
    check(explorer.here() == Explorer::box && explorer.row("logs").expanded, "on each of them");
  }

  void testUndoOfThePlanIsHintedAndThePlanSaysWhereThingsGo() {
    Explorer explorer;

    explorer.start();
    check(!hinted(explorer, "u", "undo :w"));
    explorer.type("Gdd");
    run(explorer, "w");

    const auto note = planNote(explorer.view, explorer.state, explorer.view.plan[0], {.machine = "macbook"});

    check(note.note.view() == "To the trash of macbook; u brings it back", "a delete says where it goes");
    explorer.type("y");
    applying(explorer.state, 900, false);

    const ds::Array<FileResult, 1> done{FileResult{.outcome = FileOutcome::done}};

    check(receive(explorer.state, FilesChanged{.request_id = 900, .undoable = true, .results = done.view()}));
    settle(explorer.view, explorer.state, explorer.context(), Explorer::machine);
    explorer.answer();
    check(explorer.view.message.view() == ":w · 1 of 1 applied by the runtime · u takes it back");
    check(hinted(explorer, "u", "undo :w"), "with nothing typed left to take back, u is the undo of the plan");

    // A restore, and what comes from another machine.
    run(explorer, "e docs");
    explorer.type("GgX");
    run(explorer, "w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 1 && explorer.view.plan[0].verb == PlanVerb::restore);
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.machine = "macbook"}).note.view() == "Drops its changes not staged; the runtime keeps a copy in the trash first");
    explorer.type("n");

    PlanStep carried{explorer.view.memory};

    carried.verb = PlanVerb::move;
    carried.machine = Explorer::machine;
    carried.source_machine = Explorer::box;
    check(planNote(explorer.view, explorer.state, carried, {.machine = "macbook", .source = "box"}).note.view() == "Carried from box to macbook through this window, in the background; the original goes to the trash of box once it arrived whole");
    carried.verb = PlanVerb::copy;
    check(planNote(explorer.view, explorer.state, carried, {.machine = "macbook", .source = "box"}).note.view() == "Carried from box to macbook through this window, in the background");
  }

  void testTheHeaviestSayWhichTheWindowLeavesOut() {
    Explorer explorer;

    explorer.start();
    run(explorer, "e /home/dev");
    explorer.type("gg");
    check(explorer.selected() == "/home/dev/telar");

    const auto shown = preview(explorer.view, explorer.state, explorer.context(), 0);
    const auto tagOf = [&](std::string_view name) {
      for (const auto& line : shown.heavy.view().first(shown.heavy_count)) {
        if (line.name.view() == name) {
          return std::string{std::string_view{line.tag}};
        }
      }

      return std::string{"?"};
    };

    check(shown.heavy_count == 7 && tagOf("out") == "ignored" && tagOf(".github") == "hidden" && tagOf("docs").empty() && tagOf("justfile").empty(), "what the window leaves out of its rows says why, among the heaviest");
  }

  const telar::testing::Case case_edit{"commands.edit_takes_a_file_to_its_directory", testEditTakesAFileToItsDirectory};
  const telar::testing::Case case_plan{"commands.the_plan_takes_a_yes_or_a_no_and_nothing_else", testThePlanTakesAYesOrANoAndNothingElse};
  const telar::testing::Case case_paste{"commands.a_paste_goes_nowhere_it_already_is", testAPasteGoesNowhereItAlreadyIs};
  const telar::testing::Case case_yank{"commands.a_path_copied_leaves_what_was_yanked", testAPathCopiedLeavesWhatWasYanked};
  const telar::testing::Case case_commit{"commands.a_commit_takes_its_message_without_its_quotes", testACommitTakesItsMessageWithoutItsQuotes};
  const telar::testing::Case case_said{"commands.the_keys_say_what_they_did", testTheKeysSayWhatTheyDid};
  const telar::testing::Case case_visual{"commands.a_selection_takes_the_keys_of_normal_mode", testASelectionTakesTheKeysOfNormalMode};
  const telar::testing::Case case_status{"commands.the_status_line_says_which_window_and_which_machine", testTheStatusLineSaysWhichWindowAndWhichMachine};
  const telar::testing::Case case_folds{"commands.a_machine_keeps_what_was_unfolded_on_it", testAMachineKeepsWhatWasUnfoldedOnIt};
  const telar::testing::Case case_notes{"commands.undo_of_the_plan_is_hinted_and_the_plan_says_where_things_go", testUndoOfThePlanIsHintedAndThePlanSaysWhereThingsGo};
  const telar::testing::Case case_heavy{"commands.the_heaviest_say_which_the_window_leaves_out", testTheHeaviestSayWhichTheWindowLeavesOut};

}
