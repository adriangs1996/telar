#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  using Names = std::vector<std::string>;

  // The panes of the fixture touched these, the newest first: its agent in pane 11, the first of
  // the tab, and the person at the shell of pane 13, the third.
  void touch(Explorer& explorer) {
    const auto now = explorer.now;

    explorer.disk.touches = {
        {.path = "/home/dev/telar/src/main.cpp", .actor = TouchActor::agent, .provider = AgentProvider::claude, .pane_id = 11, .verb = "Edit", .seconds = now - 40, .size = 2048},
        {.path = "/home/dev/telar/docs/images/window.png", .actor = TouchActor::agent, .provider = AgentProvider::codex, .pane_id = 77, .verb = "Read", .seconds = now - 300},
        {.path = "/home/dev/telar/docs/usage.md", .actor = TouchActor::user, .pane_id = 13, .verb = "rg", .seconds = now - 360, .size = 512},
        {.path = "/home/dev/telar/docs/usage.md", .actor = TouchActor::agent, .provider = AgentProvider::claude, .pane_id = 11, .verb = "Edit", .seconds = now - 420},
        {.path = "/home/dev/notes.txt", .actor = TouchActor::user, .pane_id = 13, .verb = "cat", .seconds = now - 500},
    };
  }

  void testTheLensListsWhatWasTouchedBelowTheRoot() {
    Explorer explorer;

    touch(explorer);
    explorer.start();

    const auto listed = lenses(explorer.view, explorer.state, explorer.context());

    check(listed[2].name == "touched" && listed[2].counted && listed[2].count == 3, "its tab counts the files touched below the root, each once");
    explorer.type("3gt");
    check(window(explorer.view).lens == Lens::touched);
    check(explorer.names() == Names{"src/main.cpp", "docs/images/window.png", "docs/usage.md"}, "the newest first, and nothing from outside the root");

    const auto edited = explorer.row("main.cpp");

    check(edited.verb.view() == "Edit" && edited.ago.view() == "40s" && edited.actor_count == 1);
    check(edited.actors[0].tone == ActorTone::claude && edited.actors[0].chip.view() == "1", "an agent's chip says the place of its pane in the tab");
    check(edited.size.view() == "2.0K" && edited.share == 1000 && explorer.row("usage.md").share == 250, "its size, against the largest of what was touched");

    const auto read = explorer.row("window.png");

    check(read.actors[0].tone == ActorTone::codex && read.actors[0].chip.view() == "·", "a pane the tab does not show has no place to say");

    const auto searched = explorer.row("usage.md");

    check(searched.verb.view() == "rg" && searched.ago.view() == "6m" && searched.actor_count == 2, "a file's row is its last touch, with a chip for each hand that touched it");
    check(searched.actors[0].tone == ActorTone::you && searched.actors[0].chip.view() == "you" && searched.actors[1].tone == ActorTone::claude);
    check(searched.unstaged == FileState::modified, "and what git says of it, as any row");

    // A row is a file as any other: the selection is its path, and Enter hands it to the pane.
    explorer.type("G");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(explorer.type("<CR>").kind == ActionKind::insert && explorer.view.text.view() == "usage.md ");

    // The lens by its name, and from a root nothing was touched below.
    explorer.type("1gt");
    explorer.type(":");
    explorer.enter("touched");
    check(window(explorer.view).lens == Lens::touched && explorer.names().size() == 3);
    explorer.type(":");
    explorer.enter("e /home/dev/telar/assets");
    explorer.type("3gt");
    check(explorer.names() == Names{"no pane touched a file below this directory lately"});
  }

  void testARowSaysWhoTouchedItAndThePreviewHow() {
    Explorer explorer;

    touch(explorer);
    explorer.start();
    explorer.type("l");
    check(explorer.row("usage.md").actor_count == 2 && explorer.row("usage.md").actors[0].chip.view() == "you", "in the tree too, before what git says");
    check(explorer.row("agents.md").actor_count == 0 && explorer.row("docs").actor_count == 0, "a file nobody touched has none, nor a directory");

    explorer.type("4j");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");

    const auto shown = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(shown.activity_count == 2, "the preview lists its touches, the newest first");
    check(shown.activity[0].who.view() == "You · pane 3" && shown.activity[0].verb.view() == "rg" && shown.activity[0].ago.view() == "6m" && shown.activity[0].actor.chip.view() == "you");
    check(shown.activity[1].who.view() == "Claude Code · pane 1" && shown.activity[1].verb.view() == "Edit" && shown.activity[1].actor.tone == ActorTone::claude);
    explorer.type("k");
    check(preview(explorer.view, explorer.state, explorer.context(), explorer.now).activity_count == 0);
  }

  void testThePlanKnowsWhatAnAgentTouchedSinceItWasListed() {
    Explorer explorer;

    touch(explorer);
    explorer.start();
    explorer.type("l4j");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    explorer.type("dd");
    explorer.type("kkdd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 2);

    const auto& touched = explorer.view.plan[0].source.view().ends_with("usage.md") ? explorer.view.plan[0] : explorer.view.plan[1];
    const auto& other = explorer.view.plan[0].source.view().ends_with("usage.md") ? explorer.view.plan[1] : explorer.view.plan[0];

    check(touchedSince(explorer.state, touched), "an agent named it after the time its listing gave it");
    check(!touchedSince(explorer.state, other), "and a file nobody touched says nothing");
  }

  void testTheKeysGoToWhatAnAgentTouched() {
    Explorer explorer;

    touch(explorer);
    explorer.start();
    check(explorer.selected() == "/home/dev/telar/docs");

    // The next one in the tree's order is two directories down, neither unfolded: both are, and
    // the selection lands on the file once they are listed.
    explorer.type("]a");
    check(explorer.selected() == "/home/dev/telar/docs/images/window.png" && explorer.row("images").expanded && explorer.row("docs").expanded, "the directories that lead to it unfold");
    explorer.type("]a");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md", "a file the person touched too counts when an agent did");
    explorer.type("]a");
    check(explorer.selected() == "/home/dev/telar/src/main.cpp" && explorer.row("src").expanded);
    explorer.type("]a");
    check(explorer.selected() == "/home/dev/telar/docs/images/window.png", "past the last it wraps around");
    explorer.type("[a");
    check(explorer.selected() == "/home/dev/telar/src/main.cpp", "and back");

    // From another lens it goes to the tree, where the file is.
    explorer.type("2gt");
    check(explorer.selected() == "/home/dev/telar/docs/remote.md");
    explorer.type("[a");
    check(window(explorer.view).lens == Lens::tree && explorer.selected() == "/home/dev/telar/docs/images/window.png", "the one before in the tree, where a directory lists before a file");

    // With no agent's touch below the root it says so and stays.
    explorer.type(":");
    explorer.enter("e /home/dev/telar/assets");
    explorer.type("]a");
    check(explorer.view.tone == Tone::error && explorer.view.message.view().starts_with("No agent touched"));
  }

  void testTouchesAreAskedAgainWhenAPaneStirs() {
    Explorer explorer;

    touch(explorer);
    explorer.start();

    const auto asked = explorer.requests;
    const auto built = window(explorer.view).built;

    // The same answer again changes nothing a window shows.
    stir(explorer.state);
    explorer.answer();
    check(explorer.requests == asked + 1 && explorer.state.touches.revision == 1 && window(explorer.view).built == built, "asked again, and no row built for the same answer");

    // Another touch: the rows of the tree stay as they are, and their chips are read again.
    const auto before = explorer.view.revision;

    explorer.disk.touches.insert(explorer.disk.touches.begin(), FileTouch{.path = "/home/dev/telar/README.md", .actor = TouchActor::user, .pane_id = 13, .verb = "cat", .seconds = explorer.now});
    stir(explorer.state);
    explorer.answer();
    check(explorer.state.touches.revision == 2 && window(explorer.view).built == built && explorer.view.revision != before);
    check(explorer.row("README.md").actor_count == 1);

    // In the lens of touches the rows are the touches: they are built again.
    explorer.type("3gt");
    check(explorer.names().size() == 4 && explorer.names().front() == "README.md");

    // A window on the panes lists no file: nothing is asked for it.
    explorer.type("4gt");

    const auto quiet = explorer.requests;

    stir(explorer.state);
    explorer.answer();
    check(explorer.requests == quiet, "a window that shows no file asks nothing of who touched them");
  }

  void testADiffUnfoldsInTheLens() {
    Explorer explorer;

    touch(explorer);
    explorer.start();
    explorer.type("3gtG=");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(explorer.names() == Names{"src/main.cpp", "docs/images/window.png", "docs/usage.md", "@@ -1,2 +1,2 @@", "-old", "+new", " context"}, "= unfolds the diff below the row of what was touched");
    check(explorer.row("usage.md").share == 250 && explorer.row("main.cpp").share == 1000, "the sizes are of the files, as before");
    explorer.type("=");
    check(explorer.names().size() == 3);
  }

  const telar::testing::Case case_diff{"touched.a_diff_unfolds_in_the_lens", testADiffUnfoldsInTheLens};
  const telar::testing::Case case_lens{"touched.the_lens_lists_what_was_touched_below_the_root", testTheLensListsWhatWasTouchedBelowTheRoot};
  const telar::testing::Case case_row{"touched.a_row_says_who_touched_it_and_the_preview_how", testARowSaysWhoTouchedItAndThePreviewHow};
  const telar::testing::Case case_plan_touched{"touched.the_plan_knows_what_an_agent_touched_since_it_was_listed", testThePlanKnowsWhatAnAgentTouchedSinceItWasListed};
  const telar::testing::Case case_keys{"touched.the_keys_go_to_what_an_agent_touched", testTheKeysGoToWhatAnAgentTouched};
  const telar::testing::Case case_asked{"touched.touches_are_asked_again_when_a_pane_stirs", testTouchesAreAskedAgainWhenAPaneStirs};

}
