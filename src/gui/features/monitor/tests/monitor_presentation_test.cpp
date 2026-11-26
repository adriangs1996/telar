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

  // Every share but the process table's is a whole percent with its sign.
  void sharesReadWhole() {
    check(wholePercent(1000).view() == "100%" && wholePercent(0).view() == "0%");
    check(wholePercent(424).view() == "42%" && wholePercent(425).view() == "43%" && wholePercent(1500).view() == "150%");
  }

  // What is left warns as it empties: much memory available is no warning.
  void headroomWarnsAsItEmpties() {
    check(headroomTone(0.9) == Tone::normal && headroomTone(0.5) == Tone::normal);
    check(headroomTone(0.3) == Tone::warm && headroomTone(0.1) == Tone::hot);
  }

  // A mount is named by its last directory in at most 12 cells.
  void mountsReadShort() {
    check(mountLabel("/").view() == "/");
    check(mountLabel("/Volumes/Try Omarchy").view() == "Try Omarchy");
    check(mountLabel("/System/Volumes/Data").view() == "Data");
    check(mountLabel("/mnt/backups/").view() == "backups");
    check(mountLabel("/Volumes/Untitled External Disk").view() == "Untitled Ex…", std::string{mountLabel("/Volumes/Untitled External Disk").view()});
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
    // After a path list's colon, and after a one-letter flag that starts a word.
    check(abbreviateHome("cc -I/Users/ada/include -L/Users/ada/lib", "/Users/ada").view() == "cc -I~/include -L~/lib");
    check(abbreviateHome("PATH=/bin:/Users/ada/bin -F/Users/ada", "/Users/ada").view() == "PATH=/bin:~/bin -F~");
    check(abbreviateHome("x--I/Users/ada --I/Users/ada", "/Users/ada").view() == "x--I/Users/ada --I/Users/ada");
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

  // The history is the runtime's: each answer replaces it, so a monitor that opens again shows what
  // the runtime read, never the window's last one spliced to it.
  void historyIsTheRuntimes() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};
    const auto answer = [&](std::uint64_t id, std::uint64_t sample, std::span<const std::uint16_t> history) {
      wait(state, id);
      check(receive(state, MonitorSnapshot{.request_id = id, .sections = MonitorSections::host, .sample = sample, .history = history}));
    };

    const ds::Array<std::uint16_t, 3> first{100, 200, 300};
    const ds::Array<std::uint16_t, 1> after_pause{900};

    answer(1, 7, first.view());
    answer(2, 7, first.view());
    check(state.cpuHistory().size() == 3 && state.cpuHistory()[2] == 300, std::to_string(state.cpuHistory().size()));
    answer(3, 20, after_pause.view());
    check(state.cpuHistory().size() == 1 && state.cpuHistory()[0] == 900, std::to_string(state.cpuHistory().size()));

    // An answer without the host's readings leaves the history as it was.
    wait(state, 4);
    check(receive(state, MonitorSnapshot{.request_id = 4, .sections = MonitorSections::processes, .sample = 21}));
    check(state.cpuHistory().size() == 1);
  }

  // The network panel shows the interfaces that carry bytes now first, then the quiet ones, each by
  // the bytes carried since the machine started, and none that never carried one.
  void interfacesShownByTraffic() {
    const ds::Array<InterfaceRow, 7> interfaces{
        InterfaceRow{.received_bytes = 900},
        InterfaceRow{.received_per_second = 10, .received_bytes = 5},
        InterfaceRow{},
        InterfaceRow{.sent_per_second = 1, .sent_bytes = 50},
        InterfaceRow{.received_bytes = 100},
        InterfaceRow{.received_bytes = 400},
        InterfaceRow{.received_bytes = 1},
    };
    ds::Array<std::uint8_t, shown_interfaces> shown{};
    const auto count = shownInterfaces(interfaces.view(), shown.viewMut());

    check(count == 4, std::to_string(count));
    check(shown[0] == 3 && shown[1] == 1 && shown[2] == 0 && shown[3] == 5, std::to_string(shown[0]) + std::to_string(shown[1]) + std::to_string(shown[2]) + std::to_string(shown[3]));
    check(shownInterfaces(interfaces.view().first(3), shown.viewMut()) == 2);
  }

  // A rate's meter fills against the highest rate of the readings in a row, of the interfaces shown,
  // and never against less than its floor.
  void ratesFillAgainstTheirPeak() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};
    const auto answer = [&](std::uint64_t id, std::uint64_t sample, std::span<const MonitorInterface> interfaces, std::uint64_t read) {
      wait(state, id);
      check(receive(state, MonitorSnapshot{.request_id = id, .sample = sample, .disk_read_per_second = read, .interfaces = interfaces}));
    };

    constexpr std::uint64_t mebibyte = std::uint64_t{1} << 20;
    const ds::Array<MonitorInterface, 1> trickle{MonitorInterface{.name = "en0", .received_per_second = 19'400, .sent_per_second = 14'900, .received_bytes = 1}};
    ds::Array<MonitorInterface, 6> busy{};

    // The sixth interface is the loudest, but four others carried more bytes and it is not shown.
    for (std::size_t index = 0; index < busy.size(); ++index) {
      busy.atMut(index) = {.name = "if", .received_per_second = 3 * mebibyte, .received_bytes = 100 - index};
    }

    busy.atMut(5).received_per_second = 50 * mebibyte;
    answer(1, 1, trickle.view(), 0);
    check(state.network_peaks.scale(network_rate_floor) == network_rate_floor && state.disk_peaks.scale(disk_rate_floor) == disk_rate_floor);
    answer(2, 2, busy.view(), 40 * mebibyte);
    check(state.network_peaks.scale(network_rate_floor) == 3 * mebibyte, std::to_string(state.network_peaks.scale(network_rate_floor)));
    check(state.disk_peaks.scale(disk_rate_floor) == 40 * mebibyte);

    // A repeat of the reading adds no peak; a reading after some the window missed starts them again.
    answer(3, 2, trickle.view(), 0);
    check(state.network_peaks.count == 2);
    answer(4, 9, trickle.view(), 0);
    check(state.network_peaks.count == 1 && state.disk_peaks.scale(disk_rate_floor) == disk_rate_floor);
  }

  // The detail held is the selected process's only when it names the same instance.
  void detailIsTheSelected() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    State state{memory};
    const ProcessInstance selected{.pid = 42, .started_seconds = 10};
    MonitorDetail detail{};

    detail.process.instance = selected;
    detail.process.nice = 7;
    state.view.selected = selected;
    wait(state, 1);
    check(receive(state, MonitorSnapshot{.request_id = 1, .detail = detail}));
    check(selectedDetail(state) != nullptr && selectedDetail(state)->process.nice == 7);

    // Another process, or the same pid started again: the detail held is the last one's.
    state.view.selected = {.pid = 43, .started_seconds = 10};
    check(selectedDetail(state) == nullptr);
    state.view.selected = {.pid = 42, .started_seconds = 11};
    check(selectedDetail(state) == nullptr);
    state.view.selected = {};
    check(selectedDetail(state) == nullptr);
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
  const telar::testing::Case case_history{"monitor_presentation.history_is_the_runtimes", historyIsTheRuntimes};
  const telar::testing::Case case_shares{"monitor_presentation.shares_read_whole", sharesReadWhole};
  const telar::testing::Case case_headroom{"monitor_presentation.headroom_warns_as_it_empties", headroomWarnsAsItEmpties};
  const telar::testing::Case case_mounts{"monitor_presentation.mounts_read_short", mountsReadShort};
  const telar::testing::Case case_interfaces{"monitor_presentation.interfaces_shown_by_traffic", interfacesShownByTraffic};
  const telar::testing::Case case_rates{"monitor_presentation.rates_fill_against_their_peak", ratesFillAgainstTheirPeak};
  const telar::testing::Case case_detail{"monitor_presentation.detail_is_the_selected", detailIsTheSelected};

}
