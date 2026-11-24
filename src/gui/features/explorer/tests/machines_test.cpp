#include "explorer_fixture.hpp"
#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  using Names = std::vector<std::string>;

  // The explorer with a second window, on the other machine at its home.
  void splitToBox(Explorer& explorer) {
    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");
  }

  void testTwoWindowsAreOnTwoMachines() {
    Explorer explorer;

    explorer.start();
    check(explorer.asked_of[1] == 0 && !explorer.remote.located, "nothing is asked of a machine with no window");
    explorer.type(":");
    explorer.enter("vs box:~");
    check(explorer.view.windows.size() == 2 && explorer.view.current == 1 && explorer.here() == Explorer::box);
    check(window(explorer.view).root.view() == "/home/ops" && explorer.names() == Names{"logs/", "site/", "deploy.sh"}, "~ is the home its runtime said, and the listing its own");
    check(explorer.view.windows[0]->root.view() == "/home/dev/telar" && explorer.view.windows[0]->machine == Explorer::machine, "the other window stays where it was");

    auto far = header(explorer.view, explorer.remote, explorer.context(), 1);
    const auto near = header(explorer.view, explorer.state, explorer.context(Explorer::machine), 0);

    check(far.machine.view() == "box" && !far.local && !far.repository, "the head says the machine, and that it is another one");
    check(near.machine.view() == "macbook" && near.local && near.repository && near.branch.view() == "lifetime-speed");

    // git is asked of the machine the window is on, about its own root.
    explorer.type(":");
    explorer.enter("e site");
    far = header(explorer.view, explorer.remote, explorer.context(), 1);
    check(window(explorer.view).root.view() == "/home/ops/site" && far.repository && far.branch.view() == "release");
    check(explorer.row("index.html").unstaged == FileState::modified && explorer.state.repository.branch.view() == "lifetime-speed", "each cache keeps what its machine said");

    // What changes on one machine builds no row of the other again, and asks it for nothing.
    const auto built = window(explorer.view).built;
    const auto asked = explorer.asked_of[1];

    explorer.type("<C-w>h");
    check(explorer.here() == Explorer::machine);
    explorer.type("jl");
    check(explorer.names()[3] == "main.cpp" && explorer.view.windows[1]->built == built && explorer.asked_of[1] == asked);
    check(explorer.remote.revision == built, "the cache of the other machine did not move");
  }

  void testCommandsAndKeysGoToAnotherMachine() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");
    explorer.enter("e box:/var/log");
    check(explorer.view.windows.size() == 1 && explorer.here() == Explorer::box && window(explorer.view).root.view() == "/var/log" && explorer.names() == Names{"syslog"}, ":e label:path takes the window there");
    check(status(explorer.view, explorer.remote, explorer.context(), 0).follows == false, "a window on another machine follows no pane");
    explorer.type(":");
    explorer.enter("sp macbook:~");
    check(explorer.view.windows.size() == 2 && explorer.here() == Explorer::machine && window(explorer.view).root.view() == "/home/dev" && !explorer.view.side_by_side);
    explorer.type("<C-w>o");

    // :machine goes to the last root the explorer had there, or the home; alone, to the next one.
    explorer.type(":");
    explorer.enter("machine box");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/var/log", "where this explorer last was on it");
    explorer.type(":");
    explorer.enter("machine");
    check(explorer.here() == Explorer::machine && explorer.view.message.view() == "macbook · local", "as gm, and it says where it went");
    explorer.type(":");
    explorer.enter("machine");
    check(explorer.here() == Explorer::box && explorer.view.message.view() == "box · remote");
    explorer.type(":");
    explorer.enter("machine nas");
    check(explorer.view.tone == Tone::error && explorer.view.message.view() == "No machine is called nas: macbook · box (here)" && explorer.here() == Explorer::box, "a name that is no machine's is answered with the ones there are");

    // gm goes to the next machine that answers, around.
    explorer.type("gm");
    check(explorer.here() == Explorer::machine && window(explorer.view).root.view() == "/home/dev");
    explorer.type("gm");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/var/log");
    explorer.type("gm");
    explorer.machines[1].reach = Reach::away;
    explorer.type("gm");
    check(explorer.here() == Explorer::machine && explorer.view.tone == Tone::error && explorer.view.message.view() == "No other machine answers for files");

    // A machine that is away says so in its window, and is asked for nothing.
    const auto asked = explorer.asked_of[1];

    explorer.type(":");
    explorer.enter("e box:~");
    check(explorer.here() == Explorer::box && explorer.asked_of[1] == asked);
    check(explorer.names() == Names{"this machine is not connected"} && look(explorer.view, explorer.remote, explorer.context(), {.window = 0, .row = 0}).kind == RowKind::note);
    explorer.machines[1].reach = Reach::silent;
    explorer.settle();
    check(explorer.names() == Names{"the runtime of this machine does not answer for files"});
    explorer.machines[1].reach = Reach::answers;
    explorer.settle();
    explorer.answer();
    check(explorer.names() == Names{"logs/", "site/", "deploy.sh"}, "and lists once it answers");
  }

  void testTabCompletesTheLabelOfAMachine() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");

    const auto completes = [&](std::string_view line) {
      complete(explorer.view, explorer.cache(explorer.here()), explorer.context(), line);
      explorer.answer();
      return std::string{explorer.view.completion.view()};
    };

    check(completes("e bo") == "e box:", "a label gets its colon");
    check(completes("vs mac") == "vs macbook:");
    check(completes("e do") == "e docs/", "a directory that starts so comes first");
    check(completes("machine b") == "machine box:");
    check(completes("machine ") == "machine " && explorer.view.message.view() == "macbook:  box:  ", "several are listed");
  }

  void testMarksAndJumpsKeepTheirMachine() {
    Explorer explorer;

    explorer.start();
    explorer.type("jma");
    explorer.type("jmB");
    check(explorer.selected() == "/home/dev/telar/justfile");
    explorer.type("gm");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/home/ops");

    // A mark in lower case is of the machine it was set on.
    explorer.type("'a");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/home/ops" && explorer.view.tone == Tone::error);
    check(explorer.view.message.view() == "Mark a is of macbook: a mark in upper case keeps its machine");
    explorer.type("jma");
    explorer.type("gg'a");
    check(window(explorer.view).root.view() == "/home/ops/site", "each machine has its own, and one set on a directory makes it the root");

    // One in upper case goes to its machine, in one jump that <C-o> takes back.
    explorer.type("'B");
    check(explorer.here() == Explorer::machine && window(explorer.view).root.view() == "/home/dev/telar" && explorer.selected() == "/home/dev/telar/justfile");
    explorer.type("<C-o>");
    check(explorer.here() == Explorer::box && window(explorer.view).root.view() == "/home/ops/site" && explorer.names() == Names{"index.html", "latest"}, "back on the other machine, listed");
    explorer.type("<C-i>");
    check(explorer.here() == Explorer::machine && window(explorer.view).root.view() == "/home/dev/telar", "and forward again");
    explorer.type(":");
    explorer.enter("marks");
    check(explorer.view.message.view() == "'a /home/dev/telar/src · 'B macbook:/home/dev/telar/justfile", ":marks lists what each marks: the ones of this machine, and the ones that keep theirs");
  }

  void testOnePlanGoesToEachMachineItsPart() {
    Explorer explorer;

    splitToBox(explorer);
    explorer.type("2jdd");
    check(explorer.row("deploy.sh").removed);
    explorer.type("<C-w>h");
    explorer.type("Gdd");
    check(explorer.row("README.md").removed && explorer.view.edits.size() == 2 && explorer.view.edits[0].machine == Explorer::box && explorer.view.edits[1].machine == Explorer::machine);
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 2, "one plan for every window");

    std::vector<std::pair<std::uint64_t, std::string>> steps;

    for (const auto& step : explorer.view.plan) {
      steps.emplace_back(step.machine, std::string{step.source.view()});
    }

    std::ranges::sort(steps);
    check(steps == std::vector<std::pair<std::uint64_t, std::string>>{{Explorer::machine, "/home/dev/telar/README.md"}, {Explorer::box, "/home/ops/deploy.sh"}}, "each line with its machine");

    const auto action = explorer.type("y");

    check(action.kind == ActionKind::apply && explorer.view.writing && explorer.view.awaited.size() == 2);

    Operations operations{};

    check(features::explorer::operations(explorer.view, Explorer::machine, operations) == 1 && operations[0].kind == FileOperationKind::trash && operations[0].source == "/home/dev/telar/README.md");
    check(features::explorer::operations(explorer.view, Explorer::box, operations) == 1 && operations[0].source == "/home/ops/deploy.sh", "each machine is sent its own operations");

    // The first machine answers: the plan waits for the other one.
    const ds::Array<FileResult, 1> done{FileResult{.outcome = FileOutcome::done}};

    applying(explorer.state, 900, false);
    applying(explorer.remote, 901, false);
    check(receive(explorer.state, FilesChanged{.request_id = 900, .undoable = true, .results = done.view()}));
    settle(explorer.view, explorer.state, explorer.context(Explorer::machine), Explorer::machine);
    check(explorer.view.writing && explorer.view.edits.size() == 1 && explorer.view.edits[0].machine == Explorer::box, "the changes of the machine that answered are written");
    check(explorer.view.message.view() == ":w · 1 of 1 applied by the runtime · 1 machine still to answer");
    check(receive(explorer.remote, FilesChanged{.request_id = 901, .undoable = true, .results = done.view()}));
    settle(explorer.view, explorer.remote, explorer.context(Explorer::box), Explorer::box);
    check(!explorer.view.writing && explorer.view.edits.empty() && explorer.view.plan.empty());
    check(explorer.view.message.view() == ":w · 2 of 2 applied by the runtime · u takes it back", "the line counts what every machine did");
    explorer.answer();

    // u takes it back on every machine it touched.
    check(explorer.type("u").kind == ActionKind::none && explorer.view.mode == Mode::question, "it asks first");
    check(explorer.type("y").kind == ActionKind::undo && explorer.view.awaited.size() == 2 && std::ranges::contains(explorer.view.wrote, Explorer::box) && std::ranges::contains(explorer.view.wrote, Explorer::machine));
  }

  void testADirectoryGoesToAnotherMachineAsAnyRow() {
    Explorer explorer;

    splitToBox(explorer);
    check(explorer.selected() == "/home/ops/logs");
    explorer.type("yy");
    explorer.type("<C-w>h");
    explorer.type("p");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].directory && explorer.view.edits[0].source_machine == Explorer::box && explorer.view.edits[0].source.view() == "/home/ops/logs", "a directory yanked on one machine is pasted on another, to be carried as its tree");
    explorer.type("u");

    // A file dragged to a window of another machine is copied there, and moved with Shift.
    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("justfile")}) == 1);

    const auto copied = aim(explorer.view, explorer.remote, explorer.context(Explorer::box), {.window = 1, .row = 0});
    const auto moved = aim(explorer.view, explorer.remote, explorer.context(Explorer::box), {.window = 1, .row = 0, .move = true});

    check(copied.count == 1 && copied.copy && moved.count == 1 && !moved.copy);
    // On its own machine it moves, and Alt copies it.
    check(!aim(explorer.view, explorer.state, explorer.context(Explorer::machine), {.window = 0, .row = explorer.at("docs")}).copy);
    check(aim(explorer.view, explorer.state, explorer.context(Explorer::machine), {.window = 0, .row = explorer.at("docs"), .copy = true}).copy);
    release(explorer.view);

    // So is a directory.
    check(grab(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = explorer.at("docs")}) == 1);
    check(aim(explorer.view, explorer.remote, explorer.context(Explorer::box), {.window = 1, .row = 0}).count == 1);
    drop(explorer.view, explorer.remote, explorer.context(Explorer::box), {.window = 1, .row = 0});
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].directory && explorer.view.edits[0].machine == Explorer::box && explorer.view.edits[0].source_machine == Explorer::machine);
  }

  void testTabCompletesAPathOfAnotherMachine() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");

    // The line is completed with the cache of the machine it names, which is asked for its
    // home and for the directory, though no window is on it.
    const auto completes = [&](std::string_view line) {
      const auto owner = completedOn(explorer.view, explorer.context(), line);

      complete(explorer.view, explorer.cache(owner), explorer.context(owner), line);
      explorer.answer();
      return std::pair{owner, std::string{explorer.view.completion.view()}};
    };

    check(completedOn(explorer.view, explorer.context(), "e do") == Explorer::machine && completedOn(explorer.view, explorer.context(), "machine box:") == Explorer::machine);
    check(completes("e box:~/lo") == std::pair{Explorer::box, std::string{"e box:~/logs/"}}, "what the other machine lists below its home");
    check(completes("vs box:s") == std::pair{Explorer::box, std::string{"vs box:site/"}}, "a path that starts nowhere starts at the home there");
    check(completes("e box:/home/ops/") == std::pair{Explorer::box, std::string{"e box:/home/ops/"}} && explorer.view.message.view() == "logs/  site/  deploy.sh  ", "several are listed, the files among them");
    check(explorer.view.windows.size() == 1 && explorer.here() == Explorer::machine, "no window went there");
    check(completes("e box:~/nothing") == std::pair{Explorer::box, std::string{"e box:/home/ops/"}} && explorer.view.tone == Tone::error, "the line stays as it was");
  }

  void testAMachineThatWentAwayKeepsItsLastListing() {
    Explorer explorer;

    splitToBox(explorer);
    check(explorer.names() == Names{"logs/", "site/", "deploy.sh"});

    // The connection ends, as a session that lost it says: what was listed stays, marked.
    explorer.machines[1].reach = Reach::away;
    reset(explorer.remote);
    explorer.settle();
    check(explorer.names() == Names{"logs/", "site/", "deploy.sh"}, "the last listing stays to be read");
    check(header(explorer.view, explorer.remote, explorer.context(), 1).away && status(explorer.view, explorer.remote, explorer.context(), 1).following.view() == "[stale]");
    explorer.type("j");
    check(explorer.selected() == "/home/ops/site", "the selection moves in it");

    // Nothing is typed that its runtime would have to do.
    for (const std::string_view keys : {"dd", "cw", "o", "ga", "p"}) {
      explorer.type(keys);
      check(explorer.view.mode == Mode::normal && explorer.view.edits.empty() && explorer.view.tone == Tone::error && explorer.view.message.view() == "box does not answer: what it lists is what it last said, and nothing changes there until it is back", "no change is typed there");
    }

    check(explorer.type("yy").kind == ActionKind::copy, "a path is still copied");

    // Back, it is read again.
    const auto asked = explorer.asked_of[1];

    explorer.machines[1].reach = Reach::answers;
    explorer.diskOf(Explorer::box).files["/home/ops"].push_back({"new.txt", false, 1, 99});
    explorer.settle();
    explorer.answer();
    check(explorer.asked_of[1] > asked && explorer.names() == Names{"logs/", "site/", "deploy.sh", "new.txt"} && !header(explorer.view, explorer.remote, explorer.context(), 1).away);
    check(status(explorer.view, explorer.remote, explorer.context(), 1).following.view() == "[fixed]");
  }

  void testAWindowOfAnotherMachineActsInTheTabThatMachineHasInView() {
    Explorer explorer;

    splitToBox(explorer);
    explorer.type("2j");
    check(explorer.selected() == "/home/ops/deploy.sh");

    // With no tab known there, nothing of the panes applies.
    check(explorer.type("@").kind == ActionKind::none && explorer.view.message.view() == "No agent in the tab box has in view to mention it to");
    explorer.type("_");
    check(window(explorer.view).root.view() == "/home/ops" && explorer.view.tone == Tone::error);

    // The tab box has in view is of a workspace, and an agent runs in it.
    explorer.machines[1].workspace = "/home/ops/site";
    explorer.machines[1].agent = 21;
    explorer.machines[1].agent_cwd = "/home/ops/site";

    const auto mentioned = explorer.type("@");

    check(mentioned.kind == ActionKind::mention && mentioned.pane == 21 && mentioned.machine == Explorer::box && explorer.view.text.view() == "@../deploy.sh ", "the agent there, by a path from where it runs");

    const auto opened = explorer.type("s");

    check(opened.kind == ActionKind::split && opened.machine == Explorer::box && explorer.view.text.view() == "/home/ops", "a shell there, where the file is");
    check(explorer.type("cd").kind == ActionKind::none && explorer.view.tone == Tone::error, "the shell of a pane of another machine does not go there");

    explorer.type("_");
    check(window(explorer.view).root.view() == "/home/ops/site", "the workspace of that tab");
    explorer.type("-");
    explorer.type("gw");
    check(window(explorer.view).root.view() == "/home/ops/site");
    explorer.type("gh");
    check(window(explorer.view).root.view() == "/home/ops");

    // On the machine that shows, a split and a mention name no machine: its own tab takes them.
    explorer.type("<C-w>h");
    check(explorer.type("s").machine == 0 && explorer.type("@").machine == 0);
  }

  void testAFileIsHandedOnlyToItsOwnMachine() {
    Explorer explorer;

    splitToBox(explorer);
    explorer.type("2j");
    check(explorer.selected() == "/home/ops/deploy.sh");

    // The focused pane is of the machine that shows: a path of another one is not typed there.
    const auto handed = explorer.type("<CR>");

    check(handed.kind == ActionKind::none && explorer.view.mode == Mode::question && explorer.view.tone == Tone::ask, "nothing is typed at the pane: a copy is offered");
    check(explorer.view.message.view() == "It is on box and the pane on macbook · bring a copy there? [y/N]");
    check(explorer.type("@").kind == ActionKind::none && explorer.type("cd").kind == ActionKind::none, "nor mentioned, nor a shell sent there");

    // gf opens it in an editor of its machine; yy copies where it is.
    const auto opened = explorer.type("gf");

    check(opened.kind == ActionKind::open && opened.machine == Explorer::box && explorer.view.paths.size() == 1 && explorer.view.paths[0].view() == "/home/ops/deploy.sh");

    const auto copied = explorer.type("yy");

    check(copied.kind == ActionKind::copy && explorer.view.text.view() == "box:/home/ops/deploy.sh");

    // On the machine that shows, all is as it was.
    explorer.type("<C-w>h");
    explorer.type("G");

    const auto typed = explorer.type("<CR>");

    check(typed.kind == ActionKind::insert && typed.pane == 13 && explorer.view.text.view() == "../README.md ");
    check(explorer.type("yy").kind == ActionKind::copy && explorer.view.text.view() == "/home/dev/telar/README.md");
  }

  const telar::testing::Case case_windows{"machines.two_windows_are_on_two_machines", testTwoWindowsAreOnTwoMachines};
  const telar::testing::Case case_go{"machines.commands_and_keys_go_to_another_machine", testCommandsAndKeysGoToAnotherMachine};
  const telar::testing::Case case_tab{"machines.tab_completes_the_label_of_a_machine", testTabCompletesTheLabelOfAMachine};
  const telar::testing::Case case_marks{"machines.marks_and_jumps_keep_their_machine", testMarksAndJumpsKeepTheirMachine};
  const telar::testing::Case case_plan{"machines.one_plan_goes_to_each_machine_its_part", testOnePlanGoesToEachMachineItsPart};
  const telar::testing::Case case_paste{"machines.a_directory_goes_to_another_machine_as_any_row", testADirectoryGoesToAnotherMachineAsAnyRow};
  const telar::testing::Case case_tab_path{"machines.tab_completes_a_path_of_another_machine", testTabCompletesAPathOfAnotherMachine};
  const telar::testing::Case case_stale{"machines.a_machine_that_went_away_keeps_its_last_listing", testAMachineThatWentAwayKeepsItsLastListing};
  const telar::testing::Case case_there{"machines.a_window_of_another_machine_acts_in_the_tab_that_machine_has_in_view", testAWindowOfAnotherMachineActsInTheTabThatMachineHasInView};
  const telar::testing::Case case_hand{"machines.a_file_is_handed_only_to_its_own_machine", testAFileIsHandedOnlyToItsOwnMachine};

}
