#include "explorer_fixture.hpp"

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  struct Step {
    PlanVerb verb;
    std::string source;
    std::string target;

    bool operator==(const Step&) const = default;
  };

  std::vector<Step> steps(const View& view) {
    std::vector<Step> result;

    for (const auto& step : view.plan) {
      result.push_back({step.verb, std::string{step.source.view()}, std::string{step.target.view()}});
    }

    return result;
  }

  void testTheListingIsEditedAsText() {
    Explorer explorer;

    explorer.start();

    // cw renames on the row: a change typed, with nothing written.
    explorer.type("l4j");
    explorer.type("cw");
    check(explorer.view.mode == Mode::insert && explorer.view.draft.view() == "usage.md", "the field starts with the name");
    explorer.enter("guide.md");
    check(explorer.view.mode == Mode::normal && explorer.view.edits.size() == 1);
    check(explorer.row("guide.md").renamed && explorer.row("guide.md").note.view() == "was usage.md");

    // dd cuts: the row is struck, and p elsewhere moves it.
    explorer.type("k");
    explorer.type("dd");
    check(explorer.row("remote.md").removed && explorer.view.edits.size() == 2);
    explorer.type("gg");
    explorer.type("l");
    explorer.type("p");
    check(explorer.view.edits.size() == 3 && explorer.names()[2] == "remote.md" && explorer.names()[6] == "remote.md");
    check(look(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = 2}).added && look(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = 6}).removed, "what a paste moves away still shows where it was");

    // o adds: a name that ends in a slash is a directory's.
    explorer.type("o");
    check(explorer.view.mode == Mode::insert && explorer.view.draft.view().empty());
    explorer.enter("icons/");
    check(explorer.view.edits.size() == 4 && explorer.view.edits[3].directory && explorer.view.edits[3].name.view() == "icons");

    // yy then p copies.
    explorer.type("G");
    explorer.type("yy");
    explorer.type("gg");
    explorer.type("p");
    check(explorer.view.edits.size() == 5);

    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan, ":w shows the plan");
    check(steps(explorer.view) == std::vector<Step>{
                                      {PlanVerb::create, "", "/home/dev/telar/assets/icons"},
                                      {PlanVerb::move, "/home/dev/telar/docs/usage.md", "/home/dev/telar/docs/guide.md"},
                                      {PlanVerb::move, "/home/dev/telar/docs/remote.md", "/home/dev/telar/assets/remote.md"},
                                      {PlanVerb::copy, "/home/dev/telar/README.md", "/home/dev/telar/assets/README.md"},
                                  },
        "what is created first, then what moves and what is copied; what a paste moved is not removed too");

    const auto action = explorer.type("y");

    check(action.kind == ActionKind::apply && !action.overwrite && explorer.view.writing);

    Operations operations{};
    const auto count = features::explorer::operations(explorer.view, Explorer::machine, operations);

    check(count == 4 && operations[0].kind == FileOperationKind::create_directory && operations[0].target == "/home/dev/telar/assets/icons");
    check(operations[1].kind == FileOperationKind::move && operations[1].identity.inode != 0, "a move says which file the listing named");
    check(features::explorer::operations(explorer.view, 2, operations) == 0, "a plan is of one machine");

    // The runtime answers: the changes are no longer pending.
    applying(explorer.state, 900, false);

    const ds::Array<FileResult, 4> results{FileResult{.outcome = FileOutcome::done}, FileResult{.outcome = FileOutcome::done}, FileResult{.outcome = FileOutcome::stale}, FileResult{.outcome = FileOutcome::renamed}};

    check(receive(explorer.state, FilesChanged{.request_id = 900, .undoable = true, .results = results.view()}));
    settle(explorer.view, explorer.state, explorer.context(), Explorer::machine);
    check(explorer.view.edits.empty() && explorer.view.plan.empty());
    check(explorer.view.message.view() == ":w · 3 applied by the runtime · 1 under another name: the target existed · 1 skipped: changed since it was listed · u takes it back" && explorer.view.tone == Tone::error);
    explorer.answer();
    // u with nothing pending takes the plan back, once a yes says so.
    check(explorer.type("u").kind == ActionKind::none && explorer.view.mode == Mode::question && explorer.view.asked == Asked::undo && explorer.view.tone == Tone::ask);
    check(explorer.view.message.view() == "Take the last :w back? What it deleted returns from the trash [y/N]");
    check(explorer.type("n").kind == ActionKind::none && explorer.view.mode == Mode::normal && explorer.view.message.view() == "Left as it is", "any other key leaves it");
    explorer.type("u");
    check(explorer.type("y").kind == ActionKind::undo && explorer.view.mode == Mode::normal && explorer.view.awaited.size() == 1, "a yes asks the runtime to");
  }

  void testChangesAreUndoneOneAtATime() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");
    explorer.type("dd");
    explorer.type("k");
    explorer.type("cw");
    explorer.enter("far.md");
    check(explorer.view.edits.size() == 2);
    explorer.type("u");
    check(explorer.view.edits.size() == 1 && !explorer.row("remote.md").renamed);
    explorer.type("u");
    check(explorer.view.edits.empty() && !explorer.row("usage.md").removed);
    check(explorer.type("u").kind == ActionKind::none && explorer.view.message.view() == "Already at the oldest change", "nothing left, and no plan to take back");

    // A new entry with no name, or a rename to the same name, is no change.
    explorer.type("o");
    cancel(explorer.view, explorer.state, explorer.context());
    check(explorer.view.edits.empty() && explorer.view.mode == Mode::normal);
    explorer.type("cw");
    explorer.enter("remote.md");
    check(explorer.view.edits.empty());
    explorer.type("cw");
    explorer.enter("a/b");
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error, "a name holds no slash");

    // A row a change added is that change undone by dd.
    explorer.type("o");
    explorer.enter("draft.md");
    check(explorer.view.edits.size() == 1 && explorer.row("draft.md").added && explorer.names()[6] == "draft.md" && window(explorer.view).cursor == 6, "the new row closes its directory, and keeps the selection");
    explorer.type("dd");
    check(explorer.view.edits.empty());

    // A count takes that many rows from the selected one, and stops at the last.
    explorer.type("gg2dd");
    check(explorer.view.edits.size() == 2 && explorer.row("assets").removed && explorer.row("docs").removed && !explorer.row("images").removed);
    explorer.type("uG9yy");
    check(explorer.view.edits.empty() && explorer.view.yanked.size() == 1 && explorer.view.yanked[0].path.view() == "/home/dev/telar/README.md");

    // With changes pending the last window does not close; :q! discards them.
    explorer.type("dd");
    check(explorer.type("q").kind == ActionKind::none && explorer.view.message.view().starts_with("E37"));
    explorer.type(":");
    check(explorer.enter("q!").kind == ActionKind::close && explorer.view.edits.empty());
  }

  void testGitTakesRowsAtOnceAndDiscardsThroughThePlan() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");

    auto action = explorer.type("ga");

    check(action.kind == ActionKind::apply && !explorer.view.writing && steps(explorer.view) == std::vector<Step>{{PlanVerb::stage, "/home/dev/telar/docs/usage.md", ""}}, "ga asks the runtime at once");
    action = explorer.type("gu");
    check(action.kind == ActionKind::apply && explorer.view.plan[0].verb == PlanVerb::unstage);
    explorer.view.plan.clear();

    explorer.type("gX");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::restore && explorer.row("usage.md").note.view() == "git restore", "gX is a change to write, as it discards work");
    explorer.type(":");
    explorer.enter("w!");
    check(explorer.view.mode == Mode::plan && explorer.view.overwrite && steps(explorer.view) == std::vector<Step>{{PlanVerb::restore, "/home/dev/telar/docs/usage.md", ""}});
    explorer.type("n");
    check(explorer.view.mode == Mode::normal && explorer.view.edits.size() == 1, "a plan cancelled leaves the changes pending");

    explorer.type("gc");
    check(explorer.view.mode == Mode::command && explorer.view.prefill.view() == "commit ");
    action = explorer.enter("commit Describe the usage");
    check(action.kind == ActionKind::commit && explorer.view.text.view() == "Describe the usage");
    explorer.type(":");
    check(explorer.enter("commit").kind == ActionKind::none && explorer.view.tone == Tone::error, "a commit needs a message");

    // = unfolds the diff below the row.
    explorer.type("=");
    check(explorer.names()[6] == "@@ -1,2 +1,2 @@" && window(explorer.view).rows[7].tone == DiffTone::removed && window(explorer.view).rows[8].tone == DiffTone::added);
    explorer.type("=");
    check(explorer.names()[6] == "src/");
  }

  void testANameStartsWithTheCaretWhereItsKeyPutsIt() {
    Explorer explorer;

    explorer.start();
    explorer.type("3j");
    check(explorer.selected() == "/home/dev/telar/README.md");
    explorer.type("cw");
    check(explorer.view.mode == Mode::insert && explorer.view.draft.view() == "README.md" && explorer.view.caret == Caret::stem, "cw selects the name up to its extension");
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("cc");
    check(explorer.view.caret == Caret::all);
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("i");
    check(explorer.view.mode == Mode::insert && explorer.view.caret == Caret::start);
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("I");
    check(explorer.view.caret == Caret::start);
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("a");
    check(explorer.view.caret == Caret::end);
    cancel(explorer.view, explorer.state, explorer.context());
    explorer.type("A");
    check(explorer.view.mode == Mode::insert && explorer.view.caret == Caret::end);

    // The name typed is the change however the typing ends: the window ends it with what the
    // field holds, on Enter, on Escape and on a click elsewhere.
    explorer.enter("READ.md");
    check(explorer.view.mode == Mode::normal && explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::rename && explorer.view.edits[0].name.view() == "READ.md");

    // A new entry starts empty, with the caret at its end.
    explorer.type("o");
    check(explorer.view.mode == Mode::insert && explorer.view.caret == Caret::end && explorer.view.draft.view().empty());

    const auto typing = hints(explorer.view, explorer.state, explorer.context());

    check(typing.count == 3 && typing.items[0].keys.view() == "<CR>" && typing.items[1].keys.view() == "<Esc>" && typing.items[1].label.view() == "end" && typing.items[2].keys.view() == "name/" && typing.items[2].label.view() == "a directory", "the hints say that both keys end the name");
    explorer.enter("");
    check(explorer.view.edits.size() == 1, "an empty name adds nothing");
  }

  void testDiscardTakesWhatADirectoryHolds() {
    Explorer explorer;

    explorer.changes.push_back({.path = "src/main.cpp", .unstaged = FileState::modified, .added = 1});
    explorer.start();
    check(explorer.selected() == "/home/dev/telar/docs");
    explorer.type("gX");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::restore && explorer.view.edits[0].path.view() == "/home/dev/telar/docs/usage.md", "gX on a directory restores what the working tree changed below it, and not what the index holds");
    check(explorer.view.message.view() == "git restore of 1 pending · :w shows it before anything is touched");
    explorer.type("u");
    check(explorer.view.edits.empty());

    // Over a selection, what each row holds.
    explorer.type("ggVGgX");
    check(explorer.view.edits.size() == 2 && explorer.view.mode == Mode::normal);
    explorer.type("u");
    explorer.type("gggX");
    check(explorer.view.edits.empty() && explorer.view.tone == Tone::error && explorer.view.message.view() == "Nothing unstaged to discard here");
  }

  const telar::testing::Case case_carets{"edits.a_name_starts_with_the_caret_where_its_key_puts_it", testANameStartsWithTheCaretWhereItsKeyPutsIt};
  const telar::testing::Case case_discard{"edits.discard_takes_what_a_directory_holds", testDiscardTakesWhatADirectoryHolds};
  const telar::testing::Case case_edited{"edits.the_listing_is_edited_as_text", testTheListingIsEditedAsText};
  const telar::testing::Case case_undone{"edits.changes_are_undone_one_at_a_time", testChangesAreUndoneOneAtATime};
  const telar::testing::Case case_git{"edits.git_takes_rows_at_once_and_discards_through_the_plan", testGitTakesRowsAtOnceAndDiscardsThroughThePlan};

}
