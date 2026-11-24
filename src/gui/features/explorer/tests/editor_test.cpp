#include "explorer_fixture.hpp"
#include <algorithm>
#include <string>
#include <string_view>
#include <vector>

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  // A row says an editor of its machine has its file in a buffer, and apart when that buffer
  // has changes not written; its preview says which pane.
  void testARowSaysAnEditorHoldsItsFile() {
    Explorer explorer;

    explorer.hold(Explorer::machine, 12, "/home/dev/telar/docs/usage.md", true);
    explorer.hold(Explorer::machine, 12, "/home/dev/telar/docs/remote.md", false);
    // The same path on another machine is another file.
    explorer.hold(Explorer::box, 12, "/home/dev/telar/docs/agents.md", true);
    // Held twice: the one with changes says so.
    explorer.hold(Explorer::machine, 40, "/home/dev/telar/docs/usage.md", false);
    explorer.start();
    explorer.type("l4j");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(explorer.row("usage.md").editor == Hold::unsaved && explorer.row("remote.md").editor == Hold::open && explorer.row("agents.md").editor == Hold::none);
    check(explorer.row("docs").editor == Hold::none, "a directory is in no buffer");

    const auto shown = preview(explorer.view, explorer.state, explorer.context(), explorer.now);
    const auto facts = shown.facts.view().first(shown.fact_count);
    const auto fact = std::ranges::find(facts, std::string_view{"Editor"}, [](const Fact& known) {
      return std::string_view{known.label};
    });

    check(fact != facts.end() && fact->value.view() == "pane 2 · changes not written", "the pane of the tab that holds it, by its number");

    // An editor of a tab that does not show has no number here.
    explorer.edited.clear();
    explorer.edited_text.clear();
    explorer.hold(Explorer::machine, 77, "/home/dev/telar/docs/usage.md", false);

    const auto elsewhere = preview(explorer.view, explorer.state, explorer.context(), explorer.now);
    const auto other = std::ranges::find(elsewhere.facts.view().first(elsewhere.fact_count), std::string_view{"Editor"}, [](const Fact& known) {
      return std::string_view{known.label};
    });

    check(other != elsewhere.facts.view().first(elsewhere.fact_count).end() && other->value.view() == "another tab · open");
  }

  // The plan warns of a file it takes from under a buffer with changes not written: the one it
  // deletes or moves, one below a directory it deletes, and the one a `:w!` replaces.
  void testThePlanWarnsOfChangesNotWritten() {
    Explorer explorer;
    const std::string_view warning = "an editor holds changes to it that were not written";

    explorer.hold(Explorer::machine, 12, "/home/dev/telar/docs/usage.md", true);
    explorer.hold(Explorer::machine, 12, "/home/dev/telar/docs/remote.md", false);
    explorer.start();
    explorer.type("l4j");
    explorer.type("dd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 1 && explorer.view.plan[0].verb == PlanVerb::remove);
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.edited = explorer.context().edited}).warning.view() == warning);
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {}).warning.view().empty(), "and says nothing while no editor holds it");
    explorer.type("n");
    explorer.type("u");

    // A buffer without changes loses nothing.
    explorer.type("kdd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].source.view() == "/home/dev/telar/docs/remote.md");
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.edited = explorer.context().edited}).warning.view().empty());
    explorer.type("n");
    explorer.type("u");

    // The directory that holds the file goes with it.
    explorer.click("docs");
    explorer.type("dd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].directory && explorer.view.plan[0].source.view() == "/home/dev/telar/docs");
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.edited = explorer.context().edited}).warning.view() == "an editor holds changes to it that were not written · with all it holds");
    explorer.type("n");
    explorer.type("u");

    // A copy that replaces what is there takes it from under its buffer.
    explorer.click("usage.md");
    explorer.type("yyp");
    explorer.type(":");
    explorer.enter("w!");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].verb == PlanVerb::copy && explorer.view.plan[0].target.view() == "/home/dev/telar/docs/usage.md");
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.edited = explorer.context().edited}).warning.view() == "replaces what is there, which goes to the trash · an editor holds changes to it that were not written");
  }

  // What an editor asks for the file it shows: the explorer on that file's directory, fixed
  // there, with the file selected.
  void testAnEditorsFileIsRevealed() {
    Explorer explorer;

    check(reveal(explorer.view, explorer.state, explorer.context(Explorer::machine), {.path = "/home/dev/telar/src/main.cpp"}), "it opens for the file");
    explorer.answer();

    const auto& opened = window(explorer.view);

    check(explorer.view.open && opened.root.view() == "/home/dev/telar/src" && !opened.follow && explorer.selected() == "/home/dev/telar/src/main.cpp");
    check(explorer.names() == std::vector<std::string>{"main.cpp"});

    // Open already, its window goes there; a buffer without a file names the editor's directory.
    check(reveal(explorer.view, explorer.state, explorer.context(), {.directory = "/home/dev/telar/docs"}));
    explorer.answer();
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && !window(explorer.view).follow);
    check(!reveal(explorer.view, explorer.state, explorer.context(), {}) && !reveal(explorer.view, explorer.state, explorer.context(), {.path = "relative.txt"}), "nothing to show is not shown");

    // While a plan waits for its answer the explorer stays where it is.
    explorer.type("dd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && !reveal(explorer.view, explorer.state, explorer.context(), {.path = "/home/dev/telar/src/main.cpp"}));
    check(window(explorer.view).root.view() == "/home/dev/telar/docs");
  }

  const telar::testing::Case case_row{"editor.a_row_says_an_editor_holds_its_file", testARowSaysAnEditorHoldsItsFile};
  const telar::testing::Case case_plan{"editor.the_plan_warns_of_changes_not_written", testThePlanWarnsOfChangesNotWritten};
  const telar::testing::Case case_reveal{"editor.an_editors_file_is_revealed", testAnEditorsFileIsRevealed};

}
