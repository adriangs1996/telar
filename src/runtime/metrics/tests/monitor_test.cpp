#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.metrics.monitor;
import telar.runtime.platform.host_metrics;
import telar.runtime.platform.process_probe;
import telar.runtime.platform.process_table;
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
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ProcessInspector inspector;
    MonitorSampler sampler{memory, inspector};
    ds::Vec<ProcessRecord, ConcurrentMemory> records{memory};
    HostDetail host{};
    Clock::time_point now{};

    void read(std::initializer_list<ProcessRecord> processes, std::span<const PaneRoot> roots = {}) {
      for (const auto& record : processes) {
        records.push(record);
      }

      sampler.update(records, host, now, roots);
      now += std::chrono::seconds{2};
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

  // A recycled pid is a new process: its time is not compared with the old one's.
  void testRecycledPid() {
    Fixture fixture;

    fixture.read({process(1, 0, "old", 5'000'000'000)});

    auto replaced = process(1, 0, "new", 6'000'000'000);

    replaced.started_seconds += 50;
    fixture.read({replaced});
    check(fixture.list(limited(1))[0].cpu_permille == 0);
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

    view.tree = true;
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
    check(snapshot->detail->children.size() == 1 && snapshot->detail->children[0] == base + 1);
    view.detail.started_seconds += 1;
    check(!fixture.sampler.answer({&view, 1})[0]);
    view.detail = {.pid = base + 2};
    check(!fixture.sampler.answer({&view, 1})[0]);
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
      sampler.update(records, host, now, {});
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

    check(decoded.processes.size() == snapshot.processes.size() && decoded.cores.size() == snapshot.cores.size());
    check(decoded.detail && decoded.detail->process.instance.pid == ::getpid());
  }

  const telar::testing::Case case_cpu_share{"monitor.cpu_share", testCpuShare};
  const telar::testing::Case case_recycled_pid{"monitor.recycled_pid", testRecycledPid};
  const telar::testing::Case case_pane_attribution{"monitor.pane_attribution", testPaneAttribution};
  const telar::testing::Case case_order_and_filter{"monitor.order_and_filter", testOrderAndFilter};
  const telar::testing::Case case_tree{"monitor.tree", testTree};
  const telar::testing::Case case_detail_names_an_instance{"monitor.detail_names_an_instance", testDetailNamesAnInstance};
  const telar::testing::Case case_snapshot_on_the_wire{"monitor.snapshot_on_the_wire", testSnapshotOnTheWire};

}
