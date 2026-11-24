#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;
  using Names = std::vector<std::string>;

  std::uint32_t countOf(const Explorer& explorer, std::size_t lens) {
    return lenses(explorer.view, explorer.cache(explorer.here()), explorer.context())[lens].count;
  }

  void filter(Explorer& explorer, std::string_view text) {
    explorer.type("/");
    typed(explorer.view, explorer.cache(explorer.here()), explorer.context(), text);
    explorer.answer();
  }

  void testTheChangesAreTheOnesBelowTheRoot() {
    Explorer explorer;

    explorer.start();
    check(countOf(explorer, 1) == 3, "at the repository's top, every changed path");
    explorer.type("2gt");
    check(explorer.names() == Names{"Staged", "docs/remote.md", "Unstaged", "docs/usage.md", "Untracked", ".github/"});

    // In a directory of the repository: what changed below it, by its path from there.
    explorer.type("1gt:");
    explorer.enter("e docs");
    check(window(explorer.view).root.view() == "/home/dev/telar/docs" && countOf(explorer, 1) == 2, "the lens counts what its window's root holds");
    explorer.type("2gt");
    check(explorer.names() == Names{"Staged", "remote.md", "Unstaged", "usage.md"}, "and lists each by its path from that root");
    check(explorer.selected() == "/home/dev/telar/docs/remote.md", "a row is the file it names, whatever the root");
    explorer.type("j=");
    check(explorer.names() == Names{"Staged", "remote.md", "Unstaged", "usage.md", "@@ -1,2 +1,2 @@", "-old", "+new", " context"}, "whose diff unfolds below it");

    // A directory with nothing changed below it says none.
    explorer.type("1gt:");
    explorer.enter("e /home/dev/telar/src");
    check(countOf(explorer, 1) == 0);
    explorer.type("2gt");
    check(explorer.names().empty());

    // A directory whose name starts as a changed one's is not that one.
    explorer.files["/home/dev/telar/doc"] = {{"notes.md", false, 5, 5}};
    explorer.type("1gt:");
    explorer.enter("e /home/dev/telar/doc");
    check(window(explorer.view).root.view() == "/home/dev/telar/doc" && countOf(explorer, 1) == 0, "the root is a directory, not the start of a name");
  }

  void testAFilterNarrowsWhatWasTouched() {
    Explorer explorer;
    const auto now = explorer.now;

    explorer.disk.touches = {
        {.path = "/home/dev/telar/src/main.cpp", .actor = TouchActor::agent, .provider = AgentProvider::claude, .pane_id = 11, .verb = "Edit", .seconds = now - 40, .size = 2048},
        {.path = "/home/dev/telar/docs/usage.md", .actor = TouchActor::user, .pane_id = 13, .verb = "rg", .seconds = now - 360, .size = 512},
    };

    explorer.start();
    explorer.type("3gt");
    check(explorer.names() == Names{"src/main.cpp", "docs/usage.md"});
    filter(explorer, "USA");
    check(explorer.names() == Names{"docs/usage.md"}, "the filter narrows the list of touches, without regard to case");
    typed(explorer.view, explorer.state, explorer.context(), "zzz");
    explorer.answer();
    check(explorer.names() == Names{"no file touched lately matches"});
    cancel(explorer.view, explorer.state, explorer.context());
    check(explorer.names() == Names{"src/main.cpp", "docs/usage.md"});
  }

  void testThePanesAreTheOnesOfTheWindowsMachine() {
    Explorer explorer;

    explorer.apart = {
        {.machine = Explorer::machine, .id = 31, .number = 1, .kind = features::explorer::PaneKind::agent, .title = "Codex", .cwd = "/home/dev/site", .workspace = "site", .state = "blocked"},
        {.machine = Explorer::box, .id = 41, .number = 1, .kind = features::explorer::PaneKind::shell, .title = "bash", .cwd = "/home/ops/logs", .workspace = "ops"},
        {.machine = Explorer::box, .id = 42, .number = 2, .kind = features::explorer::PaneKind::editor, .title = "nvim", .cwd = "/home/ops/site", .workspace = "ops", .buffer = "/home/ops/site/index.html"},
    };

    explorer.start();
    check(countOf(explorer, 3) == 4, "the panes of every workspace of the machine, and none of another one");
    explorer.type("4gt");
    check(explorer.names() == Names{"Claude Code", "nvim", "zsh", "Codex"});
    check(explorer.row("Codex").note.view() == "site · /home/dev/site" && explorer.row("zsh").note.view() == "telar · /home/dev/telar/docs", "each with its workspace and where it is");
    explorer.type("G");

    auto pane = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(pane.name.view() == "1 Codex" && pane.path.view() == "site · macbook" && pane.fact_count == 3 && pane.facts[2].label == "State" && pane.facts[2].value.view() == "blocked", "the preview says what its agent is doing");

    auto action = explorer.type("<CR>");

    check(action.kind == ActionKind::focus_pane && action.pane == 31 && action.machine == Explorer::machine, "Enter focuses a pane of another workspace as one of the tab");

    // A window on another machine lists that machine's panes.
    explorer.type(":");
    explorer.enter("e box:~");
    check(explorer.here() == Explorer::box && countOf(explorer, 3) == 2);
    explorer.type("3gtgt");
    check(window(explorer.view).lens == Lens::panes && explorer.names() == Names{"bash", "nvim"}, "gt passes through the lens of panes there too");
    explorer.type("j");
    check(explorer.selected() == "/home/ops/site/index.html", "an editor is listed by the file it is on");
    pane = preview(explorer.view, explorer.remote, explorer.context(), explorer.now);
    check(pane.fact_count == 3 && pane.facts[1].label == "Directory" && pane.facts[2].label == "Buffer" && pane.facts[2].value.view() == "index.html", "which its preview says, from its directory");
    action = explorer.type("<CR>");
    check(action.kind == ActionKind::focus_pane && action.pane == 42 && action.machine == Explorer::box, "and Enter says which machine the pane is of");
    explorer.type("gT");
    check(window(explorer.view).lens == Lens::touched);

    explorer.type("4gt");
    filter(explorer, "BAS");
    check(explorer.names() == Names{"bash"}, "a filter narrows the panes by name or directory");
  }

  const telar::testing::Case case_changes{"lenses.the_changes_are_the_ones_below_the_root", testTheChangesAreTheOnesBelowTheRoot};
  const telar::testing::Case case_touched{"lenses.a_filter_narrows_what_was_touched", testAFilterNarrowsWhatWasTouched};
  const telar::testing::Case case_panes{"lenses.the_panes_are_the_ones_of_the_windows_machine", testThePanesAreTheOnesOfTheWindowsMachine};

}
