#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.gui.features.monitor;
import telar.wire.monitor;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui::features::monitor;

  // The command takes what the fixed columns leave, every column starts a cell after the last ends,
  // and a tree's program column is wider.
  void columnsShareTheWidth() {
    const auto flat = columns(160, MonitorLayout::flat);
    const auto& last = flat[column_count - 1];

    check(last.start + last.cells == 160, std::to_string(last.start + last.cells));
    for (std::size_t index = 1; index < column_count; ++index) {
      check(flat[index].start == flat[index - 1].start + flat[index - 1].cells + 1);
    }

    check(flat[0].right && !flat[1].right && flat[static_cast<std::size_t>(Column::cpu)].right);

    const auto tree = columns(160, MonitorLayout::tree);
    const auto program = static_cast<std::size_t>(Column::program);
    const auto command = static_cast<std::size_t>(Column::command);

    check(tree[program].cells > flat[program].cells && tree[command].cells < flat[command].cells);
    check(columns(20, MonitorLayout::flat)[command].cells == 12);
  }

  // A cell holds a character, whatever its bytes: long text ends in the mark, short text is padded
  // on the left only when it aligns right.
  void fitCountsCharacters() {
    check(fit("adriangonzalez", 9, false, "+").view() == "adriango+");
    check(fit("13.6", 6, true).view() == "  13.6");
    check(fit("zsh", 6, false).view() == "zsh");
    check(fit("→ é ñ ü", 5, false).view() == "→ é …", std::string{fit("→ é ñ ü", 5, false).view()});
    check(fit("abc", 0, false).view().empty());
  }

  void amountsReadShort() {
    check(bytes(672 * 1024).view() == "672K");
    check(bytes(1'572'864).view() == "1.5M");
    check(bytes(218ULL * 1024 * 1024).view() == "218M");
    check(bytes(13ULL * 1024 * 1024 * 1024).view() == "13.0G");
    check(bytes(512).view() == "512B");
    check(percent(136).view() == "13.6" && percent(1500).view() == "150.0" && percent(0).view() == "0.0");
    check(cpuTone(249) == Tone::normal && cpuTone(250) == Tone::warm && cpuTone(800) == Tone::hot);
    check(meterTone(0.6) == Tone::normal && meterTone(0.61) == Tone::warm && meterTone(0.9) == Tone::hot);
  }

  // A row's guides say which of its ancestors' branches go on below it, and its mark whether its
  // own branch is folded.
  void treeGuides() {
    check(treePrefix({}).view().empty());
    check(treePrefix({.children = 3}).view() == "▾ ");
    check(treePrefix({.depth = 1, .guides = 1}).view() == "├─ ");
    check(treePrefix({.depth = 1, .children = 4, .folded = 9}).view() == "└─ ▸ ");
    check(treePrefix({.depth = 3, .guides = 0b101}).view() == "│     ├─ ");
  }

  void homeIsAbbreviated() {
    check(abbreviateHome("/Users/ada/Applications/Telar.app/telar-gui", "/Users/ada").view() == "~/Applications/Telar.app/telar-gui");
    check(abbreviateHome("ssh -i /Users/ada/keys/x --config=/Users/ada", "/Users/ada").view() == "ssh -i ~/keys/x --config=~");
    check(abbreviateHome("/Users/adam/bin", "/Users/ada").view() == "/Users/adam/bin");
    check(abbreviateHome("/bin/zsh", "").view() == "/bin/zsh");
  }

  void ownersAreNamed() {
    check(ownerText(ProcessOwner::agent, "Fable Architect").view() == "agent · Fable Architect");
    check(ownerText(ProcessOwner::agent_child, "Fable Architect").view() == "↳ agent · Fable Architect");
    check(ownerText(ProcessOwner::pane, "").view() == "pane");
    check(ownerText(ProcessOwner::telar, "ignored").view() == "telar" && ownerText(ProcessOwner::none, "").view() == "·");
  }

  // In an owner listing each group's title takes a row before its processes; elsewhere a row is a
  // process.
  void ownerRows() {
    const ds::Array<GroupRow, 3> groups{GroupRow{.pane_id = 9, .processes = 2}, GroupRow{.pane_id = 7, .processes = 1}, GroupRow{.processes = 3}};
    const auto layout = MonitorLayout::owner;

    check(rowCount(6, groups.view(), layout) == 9 && rowCount(6, groups.view(), MonitorLayout::flat) == 6);
    check(slotAt(0, groups.view(), layout).group && slotAt(0, groups.view(), layout).index == 0);
    check(!slotAt(2, groups.view(), layout).group && slotAt(2, groups.view(), layout).index == 1);
    check(slotAt(3, groups.view(), layout).group && slotAt(3, groups.view(), layout).index == 1);
    check(slotAt(8, groups.view(), layout).index == 5);
    for (std::size_t process = 0; process < 6; ++process) {
      const auto slot = slotAt(rowOf(process, groups.view(), layout), groups.view(), layout);

      check(!slot.group && slot.index == process, std::to_string(process));
    }

    // From a group's title the window asks from a screen before that group's first process.
    const auto asked = windowAround(5, 2, groups.view(), layout);

    check(asked.offset == 1 && asked.limit == 6, std::to_string(asked.offset));
    check(windowAround(0, 0, {}, MonitorLayout::flat).limit == 192);
  }

  // Folding a branch the view already toggled undoes the toggle; a full view forgets the oldest.
  void toggledBranches() {
    View view;

    toggle(view, 10);
    toggle(view, 11);
    toggle(view, 10);
    check(view.toggledPids().size() == 1 && view.toggledPids()[0] == 11);
    for (std::int32_t pid = 100; pid < 100 + static_cast<std::int32_t>(MonitorLimits::maximum_toggled); ++pid) {
      toggle(view, pid);
    }

    check(view.toggledPids().size() == MonitorLimits::maximum_toggled && view.toggledPids()[0] == 100);
  }

  // The window holds the rows of the answer from the offset it asked, and knows when the rows it
  // shows are past them.
  void answersFillTheWindow() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};

    state.view.visible = 10;
    state.view.first = 40;

    const auto asked = query(state);

    check(asked.offset == 30 && asked.limit == 30);
    wait(state, 5);

    ds::Array<MonitorProcess, 30> processes{};

    for (std::size_t index = 0; index < processes.size(); ++index) {
      processes.atMut(index).instance.pid = static_cast<std::int32_t>(30 + index);
    }

    check(receive(state, MonitorSnapshot{.request_id = 5, .sample = 1, .cpu_permille = 420, .matched = 100, .processes = processes.view()}));
    check(state.offset == 30 && state.processes.size() == 30 && covers(state));
    check(state.cpuHistory().size() == 1 && state.cpuHistory()[0] == 420);
    state.view.first = 55;
    check(!covers(state));

    // A listing that shrinks keeps its last screen full.
    wait(state, 6);
    check(receive(state, MonitorSnapshot{.request_id = 6, .matched = 20}));
    check(state.view.first == 10, std::to_string(state.view.first));
  }

  // An answer to a listing the view left keeps the readings but not the rows, and owes the query
  // for the current one.
  void staleListingsAreDropped() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};
    ds::Array<MonitorProcess, 2> processes{};

    processes.atMut(0).instance.pid = 1;
    processes.atMut(1).instance.pid = 2;
    state.view.visible = 10;
    wait(state, 1);
    check(receive(state, MonitorSnapshot{.request_id = 1, .sample = 3, .matched = 2, .processes = processes.view()}));
    check(!state.owed && state.matched == 2);

    wait(state, 2);
    relist(state.view).filter.assign("other");
    check(receive(state, MonitorSnapshot{.request_id = 2, .sample = 3, .cpu_permille = 70, .matched = 0}));
    check(state.owed && state.matched == 2 && state.processes.size() == 2 && state.cpu_permille == 70);

    wait(state, 3);
    check(!state.owed);
    check(receive(state, MonitorSnapshot{.request_id = 3, .sample = 4, .matched = 0}));
    check(state.matched == 0 && state.processes.empty());
  }

  // The history takes one share per reading of the runtime, however many answers repeat it.
  void historyCountsReadings() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};
    const auto answer = [&](std::uint64_t id, std::uint64_t sample, std::uint16_t share) {
      wait(state, id);
      check(receive(state, MonitorSnapshot{.request_id = id, .sample = sample, .cpu_permille = share}));
    };

    answer(1, 7, 100);
    answer(2, 7, 100);
    answer(3, 7, 100);
    answer(4, 8, 250);
    check(state.cpuHistory().size() == 2 && state.cpuHistory()[1] == 250, std::to_string(state.cpuHistory().size()));

    // A new runtime counts again from the start.
    reset(state);
    answer(5, 2, 300);
    check(state.cpuHistory().size() == 3);
  }

  const telar::testing::Case case_columns{"monitor_presentation.columns_share_the_width", columnsShareTheWidth};
  const telar::testing::Case case_fit{"monitor_presentation.fit_counts_characters", fitCountsCharacters};
  const telar::testing::Case case_amounts{"monitor_presentation.amounts_read_short", amountsReadShort};
  const telar::testing::Case case_tree{"monitor_presentation.tree_guides", treeGuides};
  const telar::testing::Case case_home{"monitor_presentation.home_is_abbreviated", homeIsAbbreviated};
  const telar::testing::Case case_owners{"monitor_presentation.owners_are_named", ownersAreNamed};
  const telar::testing::Case case_owner_rows{"monitor_presentation.owner_rows", ownerRows};
  const telar::testing::Case case_toggled{"monitor_presentation.toggled_branches", toggledBranches};
  const telar::testing::Case case_answers{"monitor_presentation.answers_fill_the_window", answersFillTheWindow};
  const telar::testing::Case case_stale{"monitor_presentation.stale_listings_are_dropped", staleListingsAreDropped};
  const telar::testing::Case case_history{"monitor_presentation.history_counts_readings", historyCountsReadings};

}
