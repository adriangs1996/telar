#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;

import telar.git.checkout;
import telar.runtime.terminal.control;
import telar.testing;
import telar.runtime.runtime.client_control;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.platform.process;
import telar.runtime.model.client_layouts;
import telar.runtime.worktrees.git_probe;
import telar.runtime.model.slot_store;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testLinkedFiles() {
    std::array<char, 64> pattern;

    std::strcpy(pattern.data(), "/tmp/telar-linked-test.XXXXXX");
    check(::mkdtemp(pattern.data()) != nullptr);
    const std::filesystem::path root{pattern.data()};
    const auto main = root / "main";
    const auto linked = root / "linked";
    const auto metadata = main / ".git/worktrees/feature";

    std::filesystem::create_directories(metadata);
    std::filesystem::create_directories(linked / "nested/child");
    std::ofstream{main / ".git/HEAD"} << "ref: refs/heads/main\n";
    std::ofstream{metadata / "HEAD"} << "ref: refs/heads/feature/topic\n";
    std::ofstream{metadata / "commondir"} << "../..\n";
    std::ofstream{linked / ".git"} << "gitdir: ../main/.git/worktrees/feature\n";
    LinkedWorktree reader;

    check(!reader.find(main.string()));
    const auto found = reader.find((linked / "nested/child").string());

    check(found && found->root_length == linked.string().size() && found->branch == "feature/topic");
    check(reader.mainBranch(linked.string()) == "main");
    std::ofstream{main / ".git/HEAD"} << "0123456789abcdef\n";
    check(!reader.mainBranch(linked.string()));
    std::filesystem::create_directory(linked / "nested/.git");
    check(!reader.find((linked / "nested/child").string()));
    std::filesystem::remove(linked / "nested/.git");
    std::ofstream{linked / "nested/.git"} << "invalid";
    check(!reader.find((linked / "nested/child").string()));
    std::filesystem::remove(linked / "nested/.git");
    std::filesystem::remove(metadata / "commondir");
    check(::mkfifo((metadata / "commondir").c_str(), 0600) == 0);
    check(!reader.find(linked.string()) && !reader.mainBranch(linked.string()));
    std::filesystem::remove(metadata / "commondir");
    std::ofstream{metadata / "commondir"} << "../..\n";

    WorktreeDetectionProbe probe;
    WorktreeDetectionRequest request{.pane = 7, .generation = 11, .cwd_revision = 13};

    request.cwd.assign((linked / "nested").string());
    const auto observation = probe.observe(request);

    check(observation.pane == 7 && observation.generation == 11 && observation.cwd_revision == 13);
    check(observation.root_length == linked.string().size() && observation.branch.view() == "feature/topic");
    std::ofstream{metadata / "HEAD"} << "ref: refs/heads/" << std::string(201, 'x') << '\n';
    check(probe.observe(request).root_length == 0);
    std::filesystem::remove_all(root);
  }

  class GatedWorktreeDetector {
  public:
    using Request = WorktreeDetectionRequest;
    using Result = WorktreeDetectionResult;

    Result observe(const Request& request) noexcept {
      released.wait(false, std::memory_order_acquire);
      Result result{.pane = request.pane, .generation = request.generation, .cwd_revision = request.cwd_revision, .root_length = request.cwd.view().size()};

      result.branch.assign("external");
      return result;
    }

    void stop() noexcept {
      release();
    }

    void release() noexcept {
      released.store(true, std::memory_order_release);
      released.notify_one();
    }

    std::atomic<bool> released{false};
  };

  void collect(RuntimeModel& model, WorktreeDetectionService<GatedWorktreeDetector&>& service) {
    pollfd completion{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&completion, 1, 1000) == 1);
    for (unsigned attempt = 0; attempt < 1000; ++attempt) {
      service.collect(model);
      if (::poll(&completion, 1, 0) == 0) {
        return;
      }

      std::this_thread::yield();
    }

    check(false);
  }

  void testDetectionLifecycle() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

    model.panes.insert(1, makeOwned<Pane>(memory, memory, 1, TabLocation{.workspace = {.id = 7}, .tab_id = 1}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
    auto& pane = *model.panes.find(1);
    GatedWorktreeDetector probe;
    WorktreeDetectionService<GatedWorktreeDetector&> service{probe};

    service.tick(model);
    pane.cwd = "/tmp/changed";
    ++pane.cwd_revision;
    probe.release();
    collect(model, service);
    check(model.workspaces.size() == 0 && model.worktrees.containing("/tmp") == nullptr);

    probe.released = false;
    service.tick(model);
    ++pane.generation;
    probe.release();
    collect(model, service);
    check(model.worktrees.containing(pane.cwd) == nullptr);
    ++pane.cwd_revision;
    service.tick(model);
    collect(model, service);
    const auto* entry = model.worktrees.containing(pane.cwd);

    check(entry != nullptr && entry->source == 7 && entry->branch.view() == "external" && entry->origin == WorktreeOrigin::external);
    const auto revision = model.workspace_revision;

    ++pane.cwd_revision;
    service.tick(model);
    check(model.workspace_revision == revision);

    for (unsigned index = 0; index < 47; ++index) {
      const auto path = "/external/" + std::to_string(index);

      model.worktrees.registerEntry(RegisterWorktree{.source = 7, .origin = WorktreeOrigin::external, .path = path, .branch = "external"});
    }

    pane.cwd = "/tmp/another";
    ++pane.cwd_revision;
    service.tick(model);
    collect(model, service);
    check(model.worktrees.containing(pane.cwd) == nullptr);
    for (unsigned index = 0; index < 16; ++index) {
      const auto path = "/managed/" + std::to_string(index);

      model.worktrees.registerEntry(RegisterWorktree{.source = 7, .path = path, .branch = "managed"});
    }

    check(model.worktrees.containing("/managed/15") != nullptr);
  }

  // A pane in a worktree's workspace that moves into another linked worktree registers it under
  // the repository the first one came from, not under the worktree's own workspace.
  void testSourceFollowsWorktreeWorkspace() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    constexpr std::uint64_t source = 3;
    constexpr std::uint64_t worktree_workspace = 7;
    const auto first = model.worktrees.registerEntry(RegisterWorktree{.source = source, .path = "/repository-first", .branch = "first"});

    model.worktrees.find(first.worktree)->workspace = worktree_workspace;
    model.panes.insert(1, makeOwned<Pane>(memory, memory, 1, TabLocation{.workspace = {.id = worktree_workspace}, .tab_id = 1}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
    auto& pane = *model.panes.find(1);
    GatedWorktreeDetector probe;
    WorktreeDetectionService<GatedWorktreeDetector&> service{probe};

    pane.cwd = "/repository-second";
    ++pane.cwd_revision;
    probe.release();
    service.tick(model);
    collect(model, service);
    const auto* second = model.worktrees.containing("/repository-second");

    check(second != nullptr && second->id != first.worktree);
    check(second->source == source, "the worktree was registered under the first worktree's workspace");
  }

  const telar::testing::Case case_linked_files{"worktree_detection.linked_files", testLinkedFiles};
  const telar::testing::Case case_detection_lifecycle{"worktree_detection.detection_lifecycle", testDetectionLifecycle};
  const telar::testing::Case case_source_follows_worktree_workspace{"worktree_detection.source_follows_worktree_workspace", testSourceFollowsWorktreeWorkspace};

}
