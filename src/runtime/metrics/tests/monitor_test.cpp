#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.metrics.monitor;
import telar.runtime.host.host_metrics;
import telar.runtime.host.process_probe;
import telar.runtime.host.process_table;
import telar.wire.monitor;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  using Clock = MonitorSampler::Clock;

  // Pids no process has, so the sampler reads no command line for them.
  constexpr pid_t base = 4'000'000;

  ProcessRecord process(pid_t pid, pid_t parent, std::string_view name, std::uint64_t cpu_nanoseconds, std::uint64_t resident = 1024) {
    ProcessRecord record{
        .pid = base + pid,
        .parent = parent == 0 ? 0 : base + parent,
        .user = 0,
        .started_seconds = 1000 + static_cast<std::uint64_t>(pid),
        .measured = true,
        .cpu_nanoseconds = cpu_nanoseconds,
        .resident_bytes = resident,
        .threads = 2,
        .state = ProcessState::running,
    };

    record.name.assign(name);
    return record;
  }

  struct Fixture {
    Fixture() = default;

    explicit Fixture(const TelarPrograms& programs)
        : sampler{memory, inspector, programs} {}

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ProcessInspector inspector;
    MonitorSampler sampler{memory, inspector};
    ds::Vec<ProcessRecord, ConcurrentMemory> records{memory};
    HostDetail host{};
    Clock::time_point now{};
    // The clock the records' starts count: a while after the processes of `process` started.
    std::chrono::microseconds started_clock{std::chrono::seconds{1200}};

    void read(std::initializer_list<ProcessRecord> processes, std::span<const PaneRoot> roots = {}, std::span<const pid_t> clients = {}) {
      for (const auto& record : processes) {
        records.push(record);
      }

      sampler.update(records, host, {.now = now, .started_clock = started_clock}, roots, clients);
      now += std::chrono::seconds{2};
      started_clock += std::chrono::seconds{2};
    }

    MonitorSnapshot hostAnswer() {
      MonitorView view{.sections = MonitorSections::host};
      const auto answers = sampler.answer({&view, 1});

      check(answers[0].hasValue());
      return *answers[0];
    }

    std::vector<MonitorProcess> list(MonitorView view, std::uint32_t* matched = nullptr) {
      view.sections = MonitorSections::processes;

      const auto answers = sampler.answer({&view, 1});

      check(answers[0].hasValue());

      const auto& snapshot = *answers[0];

      if (matched != nullptr) {
        *matched = snapshot.matched;
      }

      return {snapshot.processes.begin(), snapshot.processes.end()};
    }
  };

  MonitorView limited(std::uint16_t limit) {
    return MonitorView{.limit = limit};
  }

  // A process's share of a core is the CPU time it spent between two readings over the time
  // between them; the first reading knows none.
  void testCpuShare() {
    Fixture fixture;

    fixture.read({process(1, 0, "busy", 0), process(2, 0, "idle", 0)});
    check(!fixture.sampler.ready());
    fixture.read({process(1, 0, "busy", 3'000'000'000), process(2, 0, "idle", 0)});
    check(fixture.sampler.ready());

    const auto rows = fixture.list(limited(10));

    check(rows.size() == 2 && rows[0].name == "busy" && rows[0].cpu_permille == 1500, std::to_string(rows[0].cpu_permille));
    check(rows[1].cpu_permille == 0);
  }

  // Answers between two readings carry the same sample; the next reading counts a new one.
  void testSampleCount() {
    Fixture fixture;
    MonitorView view{.sections = MonitorSections::host};
    const auto sample = [&] {
      const auto answers = fixture.sampler.answer({&view, 1});

      check(answers[0].hasValue());
      return answers[0]->sample;
    };

    fixture.read({process(1, 0, "busy", 0)});
    fixture.read({process(1, 0, "busy", 1'000'000'000)});
    const auto first = sample();

    check(first != 0 && sample() == first);
    fixture.read({process(1, 0, "busy", 2'000'000'000)});
    check(sample() == first + 1, std::to_string(first));
  }

  // A recycled pid is a new process: its time is not compared with the old one's, and was spent
  // over its own life.
  void testRecycledPid() {
    Fixture fixture;

    fixture.read({process(1, 0, "old", 5'000'000'000)});

    auto replaced = process(1, 0, "new", 6'000'000'000);

    replaced.started_seconds += 50;
    fixture.read({replaced});

    // 6 s over the 151 s since it started at 1051 s, read at 1202 s.
    const auto share = fixture.list(limited(1))[0].cpu_permille;

    check(share == 39, std::to_string(share));
  }

  // A process that started since the last reading spent its CPU since it started, never more than
  // every core.
  void testNewProcessShare() {
    Fixture fixture;

    fixture.read({process(1, 0, "old", 0)});

    // The second reading is at 1202 s: one started half a second before, one a microsecond before.
    auto fresh = process(2, 0, "fresh", 250'000'000);
    auto instant = process(3, 0, "instant", 1'000'000'000);

    fresh.started_seconds = 1201;
    fresh.started_microseconds = 500'000;
    instant.started_seconds = 1201;
    instant.started_microseconds = 999'999;
    fixture.read({process(1, 0, "old", 0), fresh, instant});

    auto view = limited(10);

    view.sort = MonitorSort::pid;

    const auto rows = fixture.list(view);

    check(rows.size() == 3 && rows[1].cpu_permille == 500, std::to_string(rows[1].cpu_permille));
    check(rows[2].cpu_permille == MonitorLimits::whole_permille, std::to_string(rows[2].cpu_permille));
  }

  // What the cores spent that no process the runtime read accounts for is the other users' and the
  // kernel's; the processes it may not read are counted, and their threads are not.
  void testUnattributedCpu() {
    Fixture fixture;
    auto hidden = process(2, 0, "WindowServer", 0);

    hidden.measured = false;
    hidden.threads = 0;
    fixture.host.core_count = 2;
    fixture.read({process(1, 0, "busy", 0), hidden});
    // Two cores over 100 ticks each, one busy for all of them and the other for half: one core and a
    // half, of which the process read spent half a core.
    fixture.host.cores.atMut(0) = {.busy = 100, .total = 100};
    fixture.host.cores.atMut(1) = {.busy = 50, .total = 100};
    fixture.read({process(1, 0, "busy", 1'000'000'000), hidden});

    const auto snapshot = fixture.hostAnswer();

    check(snapshot.unattributed_cpu_permille == 1000, std::to_string(snapshot.unattributed_cpu_permille));
    check(snapshot.unmeasured_count == 1 && snapshot.thread_count == 2 && snapshot.process_count == 2);
  }

  // The history holds the shares of the readings in a row; a pause starts it again.
  void testHistory() {
    Fixture fixture;
    std::uint64_t ticks = 0;
    const auto read = [&](std::uint64_t busy) {
      ticks += 100;
      fixture.host.cores.atMut(0).busy += busy;
      fixture.host.cores.atMut(0).total = ticks;
      fixture.read({process(1, 0, "busy", 0)});
    };

    fixture.host.core_count = 1;
    read(0);
    check(fixture.hostAnswer().history.empty());
    read(25);
    read(50);

    auto history = fixture.hostAnswer().history;

    check(history.size() == 2 && history[0] == 250 && history[1] == 500, std::to_string(history.size()));
    fixture.now += MonitorSampler::history_gap;
    read(100);
    check(fixture.hostAnswer().history.empty() && fixture.hostAnswer().cpu_permille == 1000);
    read(10);
    history = fixture.hostAnswer().history;
    check(history.size() == 1 && history[0] == 100, std::to_string(history.size()));

    for (std::size_t reading = 0; reading < MonitorLimits::history_samples + 5; ++reading) {
      read(1);
    }

    check(fixture.hostAnswer().history.size() == MonitorLimits::history_samples);
  }

  // A process whose executable is exactly one of telar's programs is telar's, whoever started it;
  // a path that only starts with one is not. Its name is its executable's file name when the kernel's
  // is a cut of it.
  void testTelarPrograms() {
    ds::Array<char, MonitorLimits::command_bytes> text{};
    const ProcessInspector inspector;
    const auto parent = ::getppid();
    const auto line = inspector.commandLine(parent, text.viewMut());
    const auto path = line.path.view();
    if (path.empty()) {
      telar::testing::skip("this user may not read the executable of the test's parent");
    }

    const auto file = path.substr(path.rfind('/') + 1);
    TelarPrograms exact;
    TelarPrograms prefix;

    exact.paths.atMut(exact.count++).assign(path);
    prefix.paths.atMut(prefix.count++).assign(path.substr(0, path.rfind('/') + 1));

    auto record = process(1, 0, "", 0);

    record.pid = parent;
    record.name.assign(file.substr(0, 1));

    // The owner and name of the parent's row and of the other process's, whichever pid is lower;
    // copied, since a row views the sampler.
    struct Described {
      ProcessOwner owner = ProcessOwner::none;
      std::string name;
    };

    const auto described = [&](const TelarPrograms& programs) {
      Fixture fixture{programs};

      fixture.read({record, process(2, 0, "other", 0)});

      const auto rows = fixture.list(limited(10));
      const auto row = [&](pid_t pid) {
        const auto found = std::ranges::find(rows, pid, [](const MonitorProcess& listed) {
          return listed.instance.pid;
        });

        check(found != rows.end());
        return Described{.owner = found->owner, .name = std::string{found->name}};
      };

      return std::pair{row(parent), row(base + 2)};
    };

    const auto [own, other] = described(exact);

    check(own.owner == ProcessOwner::telar && other.owner == ProcessOwner::none);
    check(own.name == file, own.name);
    check(described(prefix).first.owner == ProcessOwner::none);

    // A kernel name the file's does not start with is kept: a link's or a script's.
    record.name.assign("zz-script");
    check(described(exact).first.name == "zz-script", described(exact).first.name);
  }

  // A process belongs to the pane whose shell it descends from; the telar scope keeps only those.
  void testPaneAttribution() {
    Fixture fixture;
    const PaneRoot roots[]{{.process = base + 10, .pane_id = 7}};

    fixture.read({process(10, 0, "zsh", 0), process(11, 10, "make", 0), process(12, 11, "cc", 0), process(20, 0, "launchd", 0)}, roots);

    auto view = limited(10);

    view.sort = MonitorSort::pid;
    view.scope = MonitorScope::telar;

    const auto rows = fixture.list(view);

    check(rows.size() == 3);
    for (const auto& row : rows) {
      check(row.pane_id == 7);
    }

    view.scope = MonitorScope::all;
    check(fixture.list(view).back().pane_id == 0);
  }

  // Sorting, reversing, filtering and the limit; matched counts every process the query selects.
  void testOrderAndFilter() {
    Fixture fixture;

    fixture.read({process(1, 0, "web", 0, 300), process(2, 0, "worker", 0, 100), process(3, 0, "webpack", 0, 200)});

    auto view = limited(2);

    view.sort = MonitorSort::memory;

    std::uint32_t matched = 0;
    auto rows = fixture.list(view, &matched);

    check(matched == 3 && rows.size() == 2 && rows[0].name == "web" && rows[1].name == "webpack");
    view.reverse = true;
    rows = fixture.list(view);
    check(rows[0].name == "worker");
    view.reverse = false;
    view.filter.assign("WEB");
    rows = fixture.list(view, &matched);
    check(matched == 2 && rows.size() == 2);
    view.filter.assign(std::to_string(base + 2));
    rows = fixture.list(view, &matched);
    check(matched == 1 && rows[0].name == "worker");
  }

  // A tree lists each process under its parent with its depth; an orphan of the selection is a root.
  void testTree() {
    Fixture fixture;

    fixture.read({process(1, 0, "init", 0), process(2, 1, "shell", 0), process(3, 2, "vim", 0), process(4, 1, "daemon", 0)});

    auto view = limited(10);

    view.layout = MonitorLayout::tree;
    view.sort = MonitorSort::pid;

    const auto rows = fixture.list(view);

    check(rows.size() == 4);
    check(rows[0].name == "init" && rows[0].depth == 0);
    check(rows[1].name == "shell" && rows[1].depth == 1);
    check(rows[2].name == "vim" && rows[2].depth == 2);
    check(rows[3].name == "daemon" && rows[3].depth == 1);

    view.filter.assign("vim");
    check(fixture.list(view)[0].depth == 0);
  }

  // A detail names a live instance: the reply refuses a pid that is gone or now another process,
  // and reads one that started after the last reading.
  void testDetailNamesAnInstance() {
    Fixture fixture;
    const auto self = ProcessTable::find(::getpid());

    check(self.hasValue());

    auto child = process(1, 0, "child", 0);

    child.parent = ::getpid();
    fixture.read({child, process(2, 0, "gone", 0)});

    MonitorView view{.sections = 0};

    view.detail = {.pid = ::getpid(), .started_seconds = self->started_seconds, .started_microseconds = self->started_microseconds};
    const auto answers = fixture.sampler.answer({&view, 1});
    const auto& snapshot = answers[0];

    check(snapshot && snapshot->detail && snapshot->detail->process.instance.pid == ::getpid());
    check(snapshot->detail->children.size() == 1 && snapshot->detail->children[0].pid == base + 1 && snapshot->detail->children[0].name == "child");
    view.detail.started_seconds += 1;
    check(!fixture.sampler.answer({&view, 1})[0]);
    view.detail = {.pid = base + 2};
    check(!fixture.sampler.answer({&view, 1})[0]);
  }

  // A process of a pane is the pane's, the runtime's own and its clients' are telar's, and any other
  // is no one's.
  void testOwners() {
    Fixture fixture;
    const PaneRoot roots[]{{.process = base + 10, .pane_id = 7}};
    const pid_t clients[]{base + 30};
    auto self = process(1, 0, "runtime", 0);

    self.pid = ::getpid();
    fixture.read({process(10, 0, "zsh", 0), process(11, 10, "make", 0), process(20, 0, "launchd", 0), process(30, 0, "telar-gui", 0), self}, roots, clients);

    auto view = limited(10);

    view.sort = MonitorSort::pid;

    const auto rows = fixture.list(view);
    const auto owner = [&](pid_t pid) {
      return std::ranges::find(rows, pid, [](const MonitorProcess& row) {
        return row.instance.pid;
      })->owner;
    };

    check(owner(base + 10) == ProcessOwner::pane && owner(base + 11) == ProcessOwner::pane);
    check(owner(base + 20) == ProcessOwner::none && owner(::getpid()) == ProcessOwner::telar && owner(base + 30) == ProcessOwner::telar);

    view.scope = MonitorScope::agents;
    check(fixture.list(view).empty());

    MonitorView host{.sections = MonitorSections::host};
    const auto answers = fixture.sampler.answer({&host, 1});

    check(answers[0]->telar_count == 4 && answers[0]->agent_count == 0);
  }

  // A query lists `limit` rows after the first `offset`, and matched still counts them all.
  void testWindow() {
    Fixture fixture;

    fixture.read({process(1, 0, "a", 0), process(2, 0, "b", 0), process(3, 0, "c", 0), process(4, 0, "d", 0), process(5, 0, "e", 0)});

    auto view = limited(2);

    view.sort = MonitorSort::pid;
    view.offset = 2;

    std::uint32_t matched = 0;
    const auto rows = fixture.list(view, &matched);

    check(matched == 5 && rows.size() == 2 && rows[0].name == "c" && rows[1].name == "d");
    view.offset = 4;
    check(fixture.list(view).size() == 1);
    view.offset = 9;
    check(fixture.list(view).empty());
  }

  // A tree orders siblings by their branches, so a quiet parent of a busy child goes first, and says
  // which branches go on below each row.
  void testTreeBranches() {
    Fixture fixture;

    fixture.read({process(1, 0, "root", 0), process(2, 1, "quiet", 0), process(3, 2, "busy", 0), process(4, 1, "middle", 0)});
    fixture.read({process(1, 0, "root", 0), process(2, 1, "quiet", 0), process(3, 2, "busy", 4'000'000'000), process(4, 1, "middle", 1'000'000'000)});

    auto view = limited(10);

    view.layout = MonitorLayout::tree;

    const auto rows = fixture.list(view);

    check(rows.size() == 4 && rows[0].name == "root" && rows[1].name == "quiet" && rows[2].name == "busy" && rows[3].name == "middle");
    check(rows[0].children == 2 && rows[0].branch_cpu_permille == 2500, std::to_string(rows[0].branch_cpu_permille));
    // quiet has a sibling after it, busy none, and middle is the last of root's children.
    check(rows[1].guides == 1 && rows[2].guides == 1 && rows[3].guides == 0);
  }

  // Asked to, a tree shows folded a branch with more children than folded_children, its first
  // process standing for the rest, until the query toggles it; a root never folds by default.
  void testTreeFolds() {
    Fixture fixture;

    for (int child = 0; child <= static_cast<int>(MonitorLimits::folded_children); ++child) {
      fixture.records.push(process(10 + child, 2, "helper", 0));
    }

    fixture.read({process(1, 0, "root", 0), process(2, 1, "browser", 0), process(3, 1, "editor", 0)});

    auto view = limited(32);

    view.layout = MonitorLayout::tree;
    view.sort = MonitorSort::pid;

    std::uint32_t matched = 0;
    auto rows = fixture.list(view, &matched);

    // Only a query that asks folds by default.
    check(matched == 3 + MonitorLimits::folded_children + 1);
    view.fold = true;
    rows = fixture.list(view, &matched);
    check(matched == 3 && rows.size() == 3 && rows[1].name == "browser" && rows[1].folded == MonitorLimits::folded_children + 1);
    view.toggled.atMut(0) = base + 2;
    view.toggled_count = 1;
    rows = fixture.list(view, &matched);
    check(matched == 3 + MonitorLimits::folded_children + 1 && rows[1].folded == 0 && rows[2].name == "helper");
    view.toggled.atMut(0) = base + 1;
    rows = fixture.list(view, &matched);
    check(matched == 1 && rows[0].folded == 2 + MonitorLimits::folded_children + 1);
  }

  // An owner listing puts each pane's processes together, the busiest pane first and the processes
  // of no pane last, and names every group with its count and its share.
  void testOwnerGroups() {
    Fixture fixture;
    const PaneRoot roots[]{{.process = base + 10, .pane_id = 7}, {.process = base + 20, .pane_id = 9}};
    fixture.read({process(10, 0, "zsh", 0), process(11, 10, "vim", 0), process(20, 0, "zsh", 0), process(21, 20, "cargo", 0), process(30, 0, "chrome", 0)}, roots);
    fixture.read({process(10, 0, "zsh", 0), process(11, 10, "vim", 0), process(20, 0, "zsh", 0), process(21, 20, "cargo", 2'000'000'000), process(30, 0, "chrome", 2'000'000'000)}, roots);

    auto view = limited(10);

    view.layout = MonitorLayout::owner;
    view.sections = MonitorSections::processes;

    const auto answers = fixture.sampler.answer({&view, 1});
    const auto& snapshot = *answers[0];
    const auto groups = snapshot.groups;
    const auto rows = snapshot.processes;

    check(groups.size() == 3 && groups[0].pane_id == 9 && groups[0].processes == 2 && groups[0].cpu_permille == 1000);
    check(groups[1].pane_id == 7 && groups[2].owner == ProcessOwner::none && groups[2].processes == 1);
    check(snapshot.matched == 5 && rows[0].name == "cargo" && rows[1].pane_id == 9 && rows[2].pane_id == 7 && rows[4].name == "chrome");
  }

  // A detail names its ancestors from the root down.
  void testDetailLineage() {
    Fixture fixture;
    auto shell = process(2, 1, "shell", 0);

    shell.pid = ::getppid();
    fixture.read({process(1, 0, "init", 0), shell});

    MonitorView view{.sections = 0};

    view.detail = {.pid = ::getpid()};
    const auto answers = fixture.sampler.answer({&view, 1});
    const auto& lineage = answers[0]->detail->lineage;

    check(lineage.size() == 2 && lineage[0].name == "init" && lineage[1].pid == ::getppid());
  }

  // The real host, read twice, answers a snapshot the wire carries whole.
  void testSnapshotOnTheWire() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const ProcessInspector inspector;
    MonitorSampler sampler{memory, inspector};
    ProcessTable table{memory};
    NativeHostDetail probe;
    HostDetail host{};
    ds::Vec<ProcessRecord, ConcurrentMemory> records{memory};
    auto now = Clock::now();

    for (int reading = 0; reading < 2; ++reading) {
      check(table.read(records) && probe.read(host));
      sampler.update(records, host, {.now = now, .started_clock = ProcessTable::clock()}, {});
      now += std::chrono::seconds{2};
    }

    MonitorView view{.limit = 1024};

    view.detail = {.pid = ::getpid()};
    auto answers = sampler.answer({&view, 1});

    check(answers[0].hasValue());

    auto& snapshot = answers.atMut(0).getMut();

    snapshot.request_id = 1;
    check(snapshot.process_count > 1 && !snapshot.cores.empty() && snapshot.processes.size() == std::min<std::size_t>(snapshot.process_count, 1024));
    check(snapshot.detail && !snapshot.detail->arguments.empty());

    std::vector<Byte> bytes(Codec::encodedSize(snapshot));

    static_cast<void>(Codec::encode(snapshot, std::span<Byte>{bytes}));

    std::vector<std::max_align_t> words(bytes.size());
    DecodeStorage storage{.remaining = {reinterpret_cast<Byte*>(words.data()), words.size() * sizeof(std::max_align_t)}};
    const auto decoded = Codec::decode<MonitorSnapshot>(std::span<const Byte>{bytes}, storage);

    check(decoded.processes.size() == snapshot.processes.size() && decoded.cores.size() == snapshot.cores.size() && decoded.sample == 2);
    check(decoded.detail && decoded.detail->process.instance.pid == ::getpid());
  }

  const telar::testing::Case case_cpu_share{"monitor.cpu_share", testCpuShare};
  const telar::testing::Case case_sample_count{"monitor.sample_count", testSampleCount};
  const telar::testing::Case case_recycled_pid{"monitor.recycled_pid", testRecycledPid};
  const telar::testing::Case case_new_process_share{"monitor.new_process_share", testNewProcessShare};
  const telar::testing::Case case_unattributed_cpu{"monitor.unattributed_cpu", testUnattributedCpu};
  const telar::testing::Case case_history{"monitor.history", testHistory};
  const telar::testing::Case case_telar_programs{"monitor.telar_programs", testTelarPrograms};
  const telar::testing::Case case_pane_attribution{"monitor.pane_attribution", testPaneAttribution};
  const telar::testing::Case case_order_and_filter{"monitor.order_and_filter", testOrderAndFilter};
  const telar::testing::Case case_tree{"monitor.tree", testTree};
  const telar::testing::Case case_detail_names_an_instance{"monitor.detail_names_an_instance", testDetailNamesAnInstance};
  const telar::testing::Case case_snapshot_on_the_wire{"monitor.snapshot_on_the_wire", testSnapshotOnTheWire};
  const telar::testing::Case case_owners{"monitor.owners", testOwners};
  const telar::testing::Case case_window{"monitor.window", testWindow};
  const telar::testing::Case case_tree_branches{"monitor.tree_branches", testTreeBranches};
  const telar::testing::Case case_tree_folds{"monitor.tree_folds", testTreeFolds};
  const telar::testing::Case case_owner_groups{"monitor.owner_groups", testOwnerGroups};
  const telar::testing::Case case_detail_lineage{"monitor.detail_lineage", testDetailLineage};

}
