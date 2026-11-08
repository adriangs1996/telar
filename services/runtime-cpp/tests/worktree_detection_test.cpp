#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cstdint>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <pthread.h>
#include <sys/stat.h>
#include <poll.h>
#include <ghostty/vt.h>

import std;
import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

static void testLinkedFiles() {
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

  Result observe(const Request &request) noexcept {
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

static void collect(RuntimeModel<SystemAllocator> &model, WorktreeDetectionService<SystemAllocator, GatedWorktreeDetector &> &service) {
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

static void testDetectionLifecycle() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  model.panes.insert(1, makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{.workspace = {.id = 7}, .tab_id = 1}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
  auto &pane = *model.panes.find(1);
  GatedWorktreeDetector probe;
  WorktreeDetectionService<SystemAllocator, GatedWorktreeDetector &> service{probe};
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
  const auto *entry = model.worktrees.containing(pane.cwd);
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

void testWorktreeDetection() {
  testLinkedFiles();
  testDetectionLifecycle();
}
