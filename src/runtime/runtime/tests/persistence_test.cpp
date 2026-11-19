#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <csignal>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <ghostty/vt.h>
#include <new>
#include <poll.h>
#include <pthread.h>

import std;
import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.runtime.terminal.control;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.persistence.session_store;
import telar.runtime.platform.request_worker;
import telar.runtime.runtime.execution_service;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.platform.error;
import telar.runtime.agents.snapshot;
import telar.runtime.model.slot_store;
import telar.platform.process;
import telar.runtime.model.client_layouts;
import telar.runtime.platform.event_loop;
import telar.runtime.platform.stream_read_buffer;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace std::string_literals;

  using namespace telar;
  using namespace telar::runtime;

  void testMonotonicIdentities(ConcurrentMemory& memory) {
    SlotStore<std::uint64_t, 32, ConcurrentMemory> store{memory};
    ds::Array<std::uint64_t, 32> identities{};
    std::uint64_t counter = 63;
    std::minstd_rand random{71};

    for (unsigned iteration = 0; iteration < 10000; ++iteration) {
      const auto slot = random() % identities.size();
      if (identities[slot] != 0) {
        store.erase(identities[slot]);
        check(store.find(identities[slot]) == nullptr);
      }

      identities.atMut(slot) = counter;
      store.insert(counter, ds::makeBox<std::uint64_t>(memory, counter));
      counter += 64;
      for (const auto identity : identities) {
        if (identity != 0) {
          check(store.find(identity) != nullptr && *store.find(identity) == identity);
        }
      }
    }

    check(store.nextCounter() == counter - 63);
    bool exhausted = false;

    try {
      store.insert(UINT64_MAX, ds::makeBox<std::uint64_t>(memory, UINT64_MAX));
    } catch (const std::bad_alloc&) {
      exhausted = true;
    }

    check(exhausted);
  }

  void testIndependentHandles(ConcurrentMemory& memory) {
    SlotStore<std::uint64_t, 3, ConcurrentMemory> store{memory};
    constexpr std::uint64_t high_identity = UINT64_MAX - 1;
    const auto first = store.insert(high_identity, ds::makeBox<std::uint64_t>(memory, high_identity));

    check(*store.findHandle(first) == high_identity);
    check(store.find(high_identity) == store.findHandle(first));
    store.erase(high_identity);
    check(store.findHandle(first) == nullptr);

    const auto second = store.insert(1, ds::makeBox<std::uint64_t>(memory, 1));

    check(second != first);
    check(store.findHandle(first) == nullptr);
    check(*store.findHandle(second) == 1);
    check(store.findHandle(UINT64_MAX) == nullptr);
  }

  void testExhaustedIdentities(ConcurrentMemory& memory) {
    SlotStore<std::uint64_t, 3, ConcurrentMemory> store{memory};

    store.advanceCounter(UINT64_MAX);
    check(store.nextId() == UINT64_MAX);
    store.insert(UINT64_MAX, ds::makeBox<std::uint64_t>(memory, UINT64_MAX));
    check(store.nextCounter() == 0 && *store.find(UINT64_MAX) == UINT64_MAX);
    store.erase(UINT64_MAX);
    store.advanceCounter(1);
    check(store.nextCounter() == 0 && store.size() == 0);

    bool exhausted = false;

    try {
      store.nextId();
    } catch (const std::bad_alloc&) {
      exhausted = true;
    }

    check(exhausted);
  }

  std::span<const Byte> checkpointFixture(std::span<Byte> buffer) {
    checkpoint::Writer writer{buffer, checkpoint::Counters{70, 80, 300, 900}};

    writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Restored", 7, "Shells"});
    writer.append(checkpoint::TabRecord{5, 8, "Missing"});
    constexpr char arguments[] = "/bin/sh\0-c\0read value\0";

    writer.append(checkpoint::PaneRecord{257, 5, 7, "/tmp", 90, 30, 3, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::PaneRecord{1, 5, 7, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::PaneRecord{258, 5, 8, "/telar-missing-checkpoint-directory", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
    return writer.finish();
  }

  void testCheckpointValidation() {
    ds::Array<Byte, 4096> buffer;
    const auto fixture = checkpointFixture(buffer.viewMut());
    std::size_t count = 0;
    checkpoint::Reader reader{fixture};

    reader.read([&](const auto&) {
      ++count;
    });

    check(count == 5 && reader.counters.generation == 900);

    for (std::size_t length = 0; length < fixture.size(); ++length) {
      bool rejected = false;

      try {
        checkpoint::Reader truncated{fixture.first(length)};

        truncated.read([](const auto&) {});
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected);
    }

    buffer.atMut(fixture.size()) = 0;
    bool trailing_rejected = false;

    try {
      checkpoint::Reader trailing{std::span{buffer}.first(fixture.size() + 1)};

      trailing.read([](const auto&) {});
    } catch (const EncodingError&) {
      trailing_rejected = true;
    }

    check(trailing_rejected);

    for (std::size_t capacity = 43; capacity < fixture.size(); ++capacity) {
      checkpoint::Writer bounded{buffer.viewMut().first(capacity), {}};

      bounded.append(checkpoint::WorkspaceRecord{1, "/tmp", "Example", 1, ""});
      const auto encoded = bounded.finish();
      checkpoint::Reader valid{encoded};

      valid.read([](const auto&) {});
      check(encoded.size() <= capacity);
    }

    for (std::size_t capacity = 0; capacity < 43; ++capacity) {
      bool rejected = false;

      try {
        checkpoint::Writer tiny{buffer.viewMut().first(capacity), {}};
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected);
    }
  }

  void testRestore(ConcurrentMemory& memory) {
    ds::Array<Byte, 4096> buffer;
    const auto fixture = checkpointFixture(buffer.viewMut());
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
    ClientLayouts layouts{memory};
    checkpoint::Restore restore{memory, model, panes, layouts, false};

    restore.apply(fixture);
    check(model.panes.size() == 2);
    check(model.panes.find(1)->generation == 900);
    check(model.panes.find(257)->generation == 901);
    check(model.panes.find(257)->terminal.screen.cols == 90);
    check(model.panes.find(257)->launch.bytes() == model.panes.find(1)->launch.bytes());
    check(model.panes.nextId() == 300);
    check(model.workspaces.nextId() == 70);
    check(model.next_tab_id == 80);
    const auto* workspace = model.workspaces.find(5);

    check(workspace != nullptr && workspace->tabs.size() == 1);
    check(workspace->tabs.front().panes.size() == 2);
    check(workspace->tabs.front().panes[0] == 1);
  }

  void testAtomicFile(ConcurrentMemory& memory) {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-checkpoint-test-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const auto path = std::string{directory.data()} + "/session.ckpt";
    checkpoint::FileStore file{memory, path};
    ds::Vec<Byte, ConcurrentMemory> loaded{memory};

    check(!file.load(loaded));
    ds::Array<Byte, 4096> buffer;
    const auto fixture = checkpointFixture(buffer.viewMut());

    {
      ObservationWorker<decltype(file)&> worker{std::in_place, file};

      check(worker.submit(fixture));
      worker.wait([](int error) {
        check(error == 0);
      });
    }

    check(file.load(loaded));
    check(std::ranges::equal(loaded, fixture));
    struct stat state{};

    check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
    file.quarantine();
    check(!file.load(loaded));
    check(::stat((path + ".corrupt").c_str(), &state) == 0);

    check(::mkdir(path.c_str(), 0700) == 0);
    check(file.observe(fixture) != 0);
    check(::stat(path.c_str(), &state) == 0 && S_ISDIR(state.st_mode));
    check(::rmdir(path.c_str()) == 0);
    check(::symlink((path + ".corrupt").c_str(), path.c_str()) == 0);
    bool rejected = false;

    try {
      file.load(loaded);
    } catch (const SystemError&) {
      rejected = true;
    }

    check(rejected);
    check(::unlink(path.c_str()) == 0);
    check(::unlink((path + ".corrupt").c_str()) == 0);
    check(::rmdir(directory.data()) == 0);
  }

  struct SnapshotAgents {
    const Agent* find(std::uint64_t, std::uint64_t) const noexcept {
      return nullptr;
    }

    std::uint64_t revision() const noexcept {
      return version;
    }

    std::uint64_t version = 0;
  };

  void testSnapshotChanges(ConcurrentMemory& memory) {
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
    ClientLayouts layouts{memory};
    SnapshotAgents agents;
    checkpoint::Snapshot<SnapshotAgents> snapshot;
    const auto expect = [&](bool changed) {
      check(snapshot.changed(model, layouts, agents) == changed);
      check(!snapshot.changed(model, layouts, agents));
    };

    expect(true);

    ds::Array<Byte, 4096> buffer;
    checkpoint::Restore restore{memory, model, panes, layouts, false};

    restore.apply(checkpointFixture(buffer.viewMut()));
    expect(true);
    auto* pane = model.panes.find(257);

    check(pane != nullptr);
    ++pane->cwd_revision;
    expect(true);
    pane->resize(TerminalSize{.cols = 91, .rows = 30, .cell_width_px = 0, .cell_height_px = 0});
    expect(true);
    pane->resize(TerminalSize{.cols = 91, .rows = 31, .cell_width_px = 0, .cell_height_px = 0});
    expect(true);

    constexpr ds::Array<Byte, 4> output{'t', 'e', 's', 't'};

    pane->terminal.feed(output, *pane->media);
    expect(false);
    pane->output_closed = true;
    expect(true);
    pane->exit_status = 0;
    pane->output_closed = false;
    pane->exit_status.reset();
    expect(true);
    pane->close_requested = true;
    expect(true);
    pane->close_requested = false;
    expect(true);
    ++agents.version;
    expect(true);
    ++model.workspace_revision;
    expect(true);

    model.panes.erase(1);
    expect(true);
    ++pane->cwd_revision;
    expect(true);
    const auto location = pane->location;

    model.panes.erase(257);
    expect(true);

    constexpr ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "read value"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    const auto first = panes.launch(model, nullptr, false, command, location, TerminalSize{.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}).id;

    expect(true);
    model.panes.erase(first);
    const auto replacement = panes.launch(model, nullptr, false, command, location, TerminalSize{.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0}).id;

    check(replacement != first);
    expect(true);
    model.panes.erase(replacement);
    expect(true);
  }

  void testLargePaneIdentity(ConcurrentMemory& memory) {
    constexpr std::uint64_t identity = UINT64_MAX - 2;
    ds::Array<Byte, 4096> buffer;
    checkpoint::Writer writer{buffer.viewMut(), checkpoint::Counters{2, 2, identity + 1, 10}};

    writer.append(checkpoint::WorkspaceRecord{1, "/tmp", "Large identity", 1, ""});
    constexpr char arguments[] = "/bin/sh\0-c\0printf 'restored'; read value\0";

    writer.append(checkpoint::PaneRecord{identity, 1, 1, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
    ClientLayouts layouts{memory};
    checkpoint::Restore restore{memory, model, panes, layouts, false};

    restore.apply(writer.finish());
    auto* pane = model.panes.find(identity);

    check(pane != nullptr && pane->id == identity);
    check(model.panes.nextId() == identity + 1);

    ds::Array<Event, decltype(poller)::event_capacity> ready{};
    const auto events = poller.wait(std::chrono::seconds{2}, ready.viewMut());

    check(!events.empty());
    check(pane->read());
  }

  void testWorktreeRestore() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<Byte, 4096> buffer;
    checkpoint::Writer writer{buffer.viewMut(), checkpoint::Counters{10, 10, 10, 10}};
    constexpr char arguments[] = "/bin/cat\0";
    CoordinatorReference coordinator{.pane_id = 3, .pane_generation = 4};

    coordinator.session_id.fill(7);
    writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Worktree workspace", 6, "Shell"});
    writer.append(checkpoint::PaneRecord{1, 5, 6, "/tmp", 80, 24, 1, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::WorktreeRecord{9, 5, RegisterWorktree{.source = 2, .created_by = 1, .origin = WorktreeOrigin::external, .path = "/tmp/worktree", .branch = "feature", .base = "main", .title = "A title", .brief = "A brief", .dispatched_from = "dispatcher", .coordinator = coordinator}});
    RuntimeModel model{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
    ClientLayouts layouts{memory};
    checkpoint::Restore restore{memory, model, panes, layouts, false};

    restore.apply(writer.finish());
    const auto* worktree = model.worktrees.find(9);

    check(worktree != nullptr, "the worktree was not restored under its identity");
    const auto entry = worktree->entry();

    check(entry.workspace == 5 && entry.source == 2 && entry.created_by == 1 && entry.origin == WorktreeOrigin::external);
    check(entry.path == "/tmp/worktree" && entry.branch == "feature" && entry.base == "main");
    check(entry.title == "A title" && entry.brief == "A brief" && entry.dispatched_from == "dispatcher");
    check(entry.coordinator && entry.coordinator->session_id == coordinator.session_id && entry.coordinator->pane_id == 3 && entry.coordinator->pane_generation == 4);
  }

  // A session file the runtime cannot read: it starts empty, keeps the file aside as evidence, and
  // saves the new session where the old one was.
  void testCorruptSessionQuarantined() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<Byte, 4096> fixture_buffer;
    const auto fixture = checkpointFixture(fixture_buffer.viewMut());
    std::vector<std::vector<Byte>> corrupt;

    corrupt.emplace_back(fixture.begin(), fixture.end());
    corrupt.back()[0] = 'X';
    corrupt.emplace_back(fixture.begin(), fixture.end());
    corrupt.back()[checkpoint::magic.size()] = 11;
    corrupt.emplace_back(fixture.begin(), fixture.end() - 7);

    for (const auto& bytes : corrupt) {
      ds::Array<char, 64> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-quarantine-test-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      const std::filesystem::path root{directory.data()};
      const auto path = (root / "session.ckpt").string();

      std::ofstream{path, std::ios::binary}.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
      std::filesystem::permissions(path, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
      RuntimeModel model{memory};
      LimitService limits;
      NativeEventLoop<ConcurrentMemory> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
      ClientLayouts layouts{memory};
      SnapshotAgents agents;

      {
        checkpoint::SessionStore<SnapshotAgents> store{memory};

        store.configure(model, panes, layouts, checkpoint::Options{.path = path});
        check(model.panes.size() == 0 && model.workspaces.size() == 0);
        store.finish(model, layouts, agents);
      }

      std::ifstream kept{(root / "session.ckpt.corrupt").string(), std::ios::binary};
      const std::vector<Byte> evidence{std::istreambuf_iterator<char>{kept}, {}};

      check(evidence == bytes, "the unreadable session was not kept aside");
      std::ifstream saved{path, std::ios::binary};
      const std::vector<Byte> written{std::istreambuf_iterator<char>{saved}, {}};
      checkpoint::Reader reader{written};

      reader.read([](const auto&) {});
      std::filesystem::remove_all(root);
    }
  }

  // Restores `bytes` into a model of its own, with the panes the services launch.
  struct RestoredSession {
    explicit RestoredSession(ConcurrentMemory& memory)
        : model(memory),
          poller(memory),
          panes(memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}),
          layouts(memory) {}

    void restore(ConcurrentMemory& memory, std::span<const Byte> bytes, bool resume_agents) {
      checkpoint::Restore restore{memory, model, panes, layouts, resume_agents};

      restore.apply(bytes);
    }

    RuntimeModel model;
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller;
    PaneService<NativeEventLoop<ConcurrentMemory>> panes;
    ClientLayouts layouts;
  };

  // The agents a snapshot reads: one per pane in `agents`, by pane identity.
  struct LiveAgents {
    const Agent* find(std::uint64_t pane, std::uint64_t) const noexcept {
      for (const auto& agent : agents) {
        if (agent->pane == pane) {
          return agent.get();
        }
      }

      return nullptr;
    }

    std::uint64_t revision() const noexcept {
      return 1;
    }

    std::vector<std::unique_ptr<Agent>> agents;
  };

  std::string fileText(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, {}};
  }

  // The text in `path` once a pane wrote it, or empty when none did within `limit`.
  std::string written(const std::string& path, std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;

    while (std::chrono::steady_clock::now() < deadline) {
      if (std::filesystem::exists(path)) {
        std::this_thread::sleep_for(std::chrono::milliseconds{20});
        return fileText(path);
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }

    return {};
  }

  void testAgentResume() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-resume-test-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};
    constexpr std::string_view first_session = "0123abcd-4567-89ef-0123-456789abcdef";
    constexpr std::string_view direct_session = "fedcba98-7654-3210-fedc-ba9876543210";
    const auto claude = root + "/claude";

    // An agent run as the pane's program records how it was started.
    std::ofstream{claude} << "#!/bin/sh\nprintf '%s ' \"$@\" > '" << root << "/direct'\nexec cat\n";
    check(::chmod(claude.c_str(), 0700) == 0);
    std::vector<Byte> buffer(64 * 1024);
    std::span<const Byte> session;

    {
      // Three panes: two shells whose agents share a session, and the agent itself as a program.
      ds::Array<Byte, 4096> base_buffer;
      checkpoint::Writer writer{base_buffer.viewMut(), checkpoint::Counters{10, 10, 10, 10}};
      const auto typed = [&](std::string_view name) {
        return "/bin/sh\0-c\0read -r line; printf %s \"$line\" > '"s + root + "/" + std::string{name} + "'; exec cat\0"s;
      };

      const auto first = typed("typed-first");
      const auto second = typed("typed-second");
      const auto direct = claude + '\0';

      writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Agents", 6, "Shells"});
      writer.append(checkpoint::PaneRecord{1, 5, 6, "/tmp", 80, 24, 3, first});
      writer.append(checkpoint::PaneRecord{2, 5, 6, "/tmp", 80, 24, 3, second});
      writer.append(checkpoint::PaneRecord{3, 5, 6, "/tmp", 80, 24, 1, direct});
      RestoredSession live{memory};

      live.restore(memory, writer.finish(), false);
      check(live.model.panes.size() == 3);
      LiveAgents agents;

      for (const auto& [pane, session_id] : {std::pair{1, first_session}, std::pair{2, first_session}, std::pair{3, direct_session}}) {
        auto agent = std::make_unique<Agent>(pane, live.model.panes.find(pane)->generation);

        agent->provider = AgentProvider::claude;
        agent->setSession(session_id);
        check(agent->reportTitle("Fix the parser"));
        agent->title_source = AgentTitleSource::manual;
        agents.agents.push_back(std::move(agent));
      }

      std::size_t dropped = 0;

      session = checkpoint::Snapshot<LiveAgents>::encode(live.model, live.layouts, agents, buffer, dropped);
      check(dropped == 0);
    }

    for (const auto name : {"typed-first", "typed-second", "direct"}) {
      std::filesystem::remove(root + "/" + name);
    }

    // Without resuming, the shells get no input and the agent starts as it was.
    {
      RestoredSession restored{memory};

      restored.restore(memory, session, false);
      check(written(root + "/direct", std::chrono::seconds{5}) == " ", "the agent program did not start as it was");
      check(!std::filesystem::exists(root + "/typed-first") && !std::filesystem::exists(root + "/typed-second"), "a resume was typed although resuming is off");
    }

    std::filesystem::remove(root + "/direct");
    RestoredSession restored{memory};

    restored.restore(memory, session, true);
    check(written(root + "/typed-first", std::chrono::seconds{5}) == "claude --resume " + std::string{first_session}, "the shell's agent was not resumed");
    check(written(root + "/direct", std::chrono::seconds{5}) == "--resume " + std::string{direct_session} + " ", "the agent program was not relaunched on its session");
    check(written(root + "/typed-second", std::chrono::milliseconds{500}).empty(), "one session was resumed twice");

    // The next checkpoint keeps what the restored panes resume, before their agents report again.
    std::vector<Byte> again(64 * 1024);
    std::size_t dropped = 0;
    std::vector<std::tuple<std::uint64_t, std::string, std::string>> kept;
    checkpoint::Reader reader{checkpoint::Snapshot<SnapshotAgents>::encode(restored.model, restored.layouts, SnapshotAgents{}, again, dropped)};

    reader.read([&]<typename Record>(const Record& record) {
      if constexpr (std::same_as<Record, checkpoint::PaneRecord>) {
        if (!record.session.empty()) {
          kept.emplace_back(record.id, std::string{record.session}, std::string{record.title});
        }
      }
    });

    check(std::ranges::count(kept, std::tuple<std::uint64_t, std::string, std::string>{1, std::string{first_session}, "Fix the parser"}) == 1);
    check(std::ranges::count(kept, std::tuple<std::uint64_t, std::string, std::string>{3, std::string{direct_session}, "Fix the parser"}) == 1);
    std::filesystem::remove_all(root);
  }

  // A checkpoint write that fails, as on a full disk, is tried again without the session changing.
  void testWriteFailureRetried() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-retry-test-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};
    const auto path = root + "/session.ckpt";
    RestoredSession session{memory};
    ds::Array<Byte, 4096> buffer;
    SnapshotAgents agents;

    session.restore(memory, checkpointFixture(buffer.viewMut()), false);
    checkpoint::SessionStore<SnapshotAgents> store{memory};

    store.configure(session.model, session.panes, session.layouts, checkpoint::Options{.path = path});
    check(::mkdir(path.c_str(), 0700) == 0);
    const auto start = std::chrono::steady_clock::now();
    const auto settle = [&] {
      pollfd done{.fd = store.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&done, 1, 5000) == 1);
      store.collect();
    };

    // The first write, once the session settled, finds a directory where the file goes.
    store.tick(session.model, session.layouts, agents, start);
    store.tick(session.model, session.layouts, agents, start + std::chrono::seconds{10});
    settle();
    check(!std::filesystem::is_regular_file(path));
    check(::rmdir(path.c_str()) == 0);

    store.tick(session.model, session.layouts, agents, start + std::chrono::seconds{20});
    settle();
    check(std::filesystem::is_regular_file(path), "the failed checkpoint was never written again");
    const auto bytes = fileText(path);
    std::size_t panes = 0;
    checkpoint::Reader reader{std::span{reinterpret_cast<const Byte*>(bytes.data()), bytes.size()}};

    reader.read([&]<typename Record>(const Record&) {
      panes += std::same_as<Record, checkpoint::PaneRecord>;
    });

    check(panes == 2);
    std::filesystem::remove_all(root);
  }

  // A worktree record that later validation rejects is skipped; the rest of the session restores.
  void testInvalidWorktreeSkipped() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<Byte, 4096> buffer;
    checkpoint::Writer writer{buffer.viewMut(), checkpoint::Counters{10, 10, 10, 10}};
    constexpr char arguments[] = "/bin/cat\0";

    writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Kept", 6, "Shell"});
    writer.append(checkpoint::PaneRecord{1, 5, 6, "/tmp", 80, 24, 1, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::WorktreeRecord{9, 5, RegisterWorktree{.source = 5, .path = "/relative-worktree", .branch = "feature"}});
    const auto encoded = writer.finish();
    // The writer refuses a relative path, so the record is edited in place, as an older release or
    // a damaged file could hold it.
    std::vector<Byte> bytes{encoded.begin(), encoded.end()};
    constexpr std::string_view absolute = "/relative-worktree";
    const auto found = std::ranges::search(bytes, std::span{reinterpret_cast<const Byte*>(absolute.data()), absolute.size()});

    check(!found.empty());
    found.front() = 'x';
    RestoredSession restored{memory};

    restored.restore(memory, bytes, false);
    check(restored.model.workspaces.find(5) != nullptr && restored.model.panes.size() == 1, "one bad worktree lost the session");
    check(std::ranges::count(restored.model.worktrees.items(), nullptr) == std::ranges::ssize(restored.model.worktrees.items()), "the invalid worktree was restored");
  }

  // A workspace none of whose panes could start again is not restored empty, and the worktree it
  // held forgets it.
  void testEmptyWorkspacesDropped() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::Array<Byte, 4096> buffer;
    checkpoint::Writer writer{buffer.viewMut(), checkpoint::Counters{10, 10, 10, 10}};
    constexpr char arguments[] = "/bin/cat\0";

    writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Kept", 6, "Shell"});
    writer.append(checkpoint::PaneRecord{1, 5, 6, "/tmp", 80, 24, 1, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::WorkspaceRecord{7, "/telar-missing-workspace", "Gone", 8, "Shell"});
    writer.append(checkpoint::PaneRecord{2, 7, 8, "/telar-missing-checkpoint-directory", 80, 24, 1, {arguments, sizeof(arguments) - 1}});
    writer.append(checkpoint::WorktreeRecord{9, 7, RegisterWorktree{.source = 5, .path = "/tmp/telar-gone-worktree", .branch = "feature"}});
    RestoredSession restored{memory};

    restored.restore(memory, writer.finish(), false);
    check(restored.model.workspaces.find(5) != nullptr);
    check(restored.model.workspaces.find(7) == nullptr, "a workspace with no pane was restored");
    const auto* worktree = restored.model.worktrees.find(9);

    check(worktree != nullptr && !worktree->workspace, "the worktree still points at the dropped workspace");
  }

  void testPersistence() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;

    testMonotonicIdentities(memory);
    testIndependentHandles(memory);
    testExhaustedIdentities(memory);
    testRestore(memory);
    testLargePaneIdentity(memory);
    testSnapshotChanges(memory);
    testAtomicFile(memory);
  }

  const telar::testing::Case case_persistence{"persistence.persistence", testPersistence};
  const telar::testing::Case case_checkpoint_validation{"persistence.checkpoint_validation", testCheckpointValidation};
  const telar::testing::Case case_worktree_restore{"persistence.worktree_restore", testWorktreeRestore};
  const telar::testing::Case case_corrupt_session_quarantined{"persistence.corrupt_session_quarantined", testCorruptSessionQuarantined};
  const telar::testing::Case case_agent_resume{"persistence.agent_resume", testAgentResume};
  const telar::testing::Case case_write_failure_retried{"persistence.write_failure_retried", testWriteFailureRetried};
  const telar::testing::Case case_invalid_worktree_skipped{"persistence.invalid_worktree_skipped", testInvalidWorktreeSkipped};
  const telar::testing::Case case_empty_workspaces_dropped{"persistence.empty_workspaces_dropped", testEmptyWorkspacesDropped};

}
