#include <cstdlib>
#include <cstdio>

import std;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static constexpr TerminalSize size{80, 24, 0, 0};
static constexpr std::array<std::string_view, 1> arguments{"/bin/cat"};

template <typename Request>
static void expectUnavailable(ProtocolPeer &peer, std::ostream &dump, const Request &request) {
  const auto failure = peer.exchange<RequestFailed>(request);
  check(failure.code == FailureCode::invalid_request && failure.message == "cwd source pane is unavailable");
  peer.record(dump, failure);
}

static void checkAuthority(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  ProtocolPeer outsider{socket};
  const auto root = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const Launch inherited{.cwd = "/unavailable-launch-directory", .cwd_source = root.pane_id, .arguments = arguments};

  expectUnavailable(outsider, dump, CreateWorkspace{.request_id = 2, .size = size, .name = "Fixture", .launch = inherited});
  expectUnavailable(outsider, dump, OpenPane{.request_id = 3, .size = size, .launch = inherited});

  const auto reused = owner.exchange<PaneOpened>(OpenPane{.request_id = 4, .size = size, .launch = inherited});
  check(!reused.created && reused.pane_id == root.pane_id);
  const auto tab = owner.exchange<TabCreated>(CreateTab{.request_id = 5, .workspace = root.location.workspace, .label = "Inherited", .size = size, .launch = inherited});
  check(tab.location.workspace.id == root.location.workspace.id && tab.location.tab_id != root.location.tab_id);
  const auto split = owner.exchange<PaneOpened>(CreatePane{.request_id = 6, .location = root.location, .size = size, .launch = inherited});
  check(split.created && split.location.workspace.id == root.location.workspace.id && split.location.tab_id == root.location.tab_id && split.pane_id != root.pane_id);
  dump << "inherited-open-tab-split\n";

  expectUnavailable(owner, dump, CreatePane{.request_id = 7, .location = tab.location, .size = size, .launch = inherited});
  const auto remote = outsider.exchange<PaneOpened>(CreateWorkspace{.request_id = 8, .size = size, .name = "Fixture", .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  outsider.send(DetachPane{remote.pane_id});
  outsider.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 9, .workspace = remote.location.workspace});
  expectUnavailable(owner, dump, CreateTab{.request_id = 10, .workspace = remote.location.workspace, .label = "Cross workspace", .size = size, .launch = inherited});

  owner.send(DetachPane{root.pane_id});
  expectUnavailable(owner, dump, CreateWorkspace{.request_id = 11, .size = size, .name = "Fixture", .launch = inherited});
  owner.exchange<PaneOpened>(OpenPane{.request_id = 12, .target = {.kind = PaneTarget::Kind::pane, .id = root.pane_id}, .size = size});
  owner.send(ClosePane{.request_id = 15, .pane_id = root.pane_id});
  expectUnavailable(owner, dump, CreateWorkspace{.request_id = 13, .size = size, .name = "Fixture", .launch = inherited});

  const auto workspace = owner.exchange<PaneOpened>(CreateWorkspace{.request_id = 14, .size = size, .name = "Fixture", .create_cwd = true, .launch = Launch{.cwd = "/unavailable-launch-directory", .cwd_source = split.pane_id, .arguments = arguments}});
  check(workspace.created && workspace.location.workspace.id != root.location.workspace.id);
  dump << "inherited-workspace\n";
}

static void checkExitedSource(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  const std::array<std::string_view, 3> exiting{"/bin/sh", "-c", "exit 0"};
  const auto pane = owner.exchange<PaneOpened>(CreateWorkspace{.request_id = 20, .size = size, .name = "Fixture", .launch = Launch{.cwd = "/", .arguments = exiting}});
  const auto exited = owner.receive<PaneExited>();
  check(exited.pane_id == pane.pane_id);
  expectUnavailable(owner, dump, CreateWorkspace{.request_id = 21, .size = size, .name = "Fixture", .launch = Launch{.cwd = "/unavailable-launch-directory", .cwd_source = pane.pane_id, .arguments = arguments}});
}

static void checkDefaultTab(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  const std::array<std::string_view, 3> protected_arguments{"/bin/sh", "-c", "printf 'launch-ready\\n'; exec /bin/cat"};
  const auto root = owner.exchange<PaneOpened>(OpenPane{.request_id = 30, .size = size, .launch = Launch{.cwd = "/", .arguments = protected_arguments}});
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    const auto text = owner.exchange<PaneText>(ReadPane{.request_id = 31, .pane_id = root.pane_id, .pane_generation = root.pane_generation, .rows = 24, .source = PaneTextSource::screen});
    if (text.text.find("launch-ready") != std::string_view::npos) {
      break;
    }
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  const Launch launch{.cwd = "/", .arguments = arguments};
  ProtocolPeer lagging{socket, false};
  const auto held = lagging.exchange<PaneOpened>(OpenPane{.request_id = 1, .target = {.kind = PaneTarget::Kind::pane, .id = root.pane_id}, .size = size});
  check(held.pane_id == root.pane_id);
  const auto second = owner.exchange<TabCreated>(CreateTab{.request_id = 32, .workspace = root.location.workspace, .label = "Second", .size = size, .launch = launch});
  owner.send(ClosePane{.request_id = 33, .pane_id = root.pane_id});
  const auto unavailable = owner.exchange<RequestFailed>(OpenPane{.request_id = 34, .target = {.kind = PaneTarget::Kind::workspace, .id = root.location.workspace.id}, .size = size});
  check(unavailable.code == FailureCode::pane_not_found && unavailable.message == "workspace has no running pane");
  owner.record(dump, unavailable);
  const auto split = owner.exchange<RequestFailed>(CreatePane{.request_id = 35, .location = root.location, .size = size, .launch = launch});
  check(split.code == FailureCode::pane_not_found && split.message == "tab not found");
  owner.record(dump, split);

  auto reopened = owner.exchange<PaneOpened>(OpenPane{.request_id = 36, .size = size, .launch = launch});
  check(reopened.created && reopened.pane_id != root.pane_id && reopened.pane_id != second.root_pane_id);
  check(reopened.location.workspace.id == root.location.workspace.id && reopened.location.tab_id == root.location.tab_id);
  reopened.pane_id = 1;
  reopened.pane_generation = 1;
  reopened.location.workspace.id = 1;
  reopened.location.tab_id = 1;
  owner.record(dump, reopened);
}

template <typename Request>
static void expectUnsupportedEnvironment(ProtocolPeer &peer, std::ostream &dump, const Request &request) {
  const auto failure = peer.exchange<RequestFailed>(request);
  check(failure.code == FailureCode::invalid_request && failure.message == "custom pane environment is not supported");
  peer.record(dump, failure);
}

static void checkEnvironment(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  const auto root = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto tracked = owner.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = 2, .source = root.location.workspace.id, .path = "/tmp", .branch = "environment-fixture"});
  const std::array<std::string_view, 1> missing{"telar-missing-environment-fixture-command"};
  const std::array<EnvironmentEntry, 1> environment{{{"TELAR_FIXTURE", "value"}}};
  const std::array<Launch, 3> launches{{
      {.cwd = "/", .arguments = missing, .environment_mode = EnvironmentMode::replace},
      {.cwd = "/", .arguments = missing, .environment = environment},
      {.cwd = "/", .arguments = missing, .environment_mode = EnvironmentMode::replace, .environment = environment},
  }};

  std::uint64_t request_id = 3;
  for (const auto &launch : launches) {
    const auto reused = owner.exchange<PaneOpened>(OpenPane{.request_id = request_id++, .size = size, .launch = launch});
    check(reused.pane_id == root.pane_id && !reused.created);
    owner.record(dump, reused);
    auto other_directory = launch;
    other_directory.cwd = "/var";
    expectUnsupportedEnvironment(owner, dump, OpenPane{.request_id = request_id++, .size = size, .launch = other_directory});
    expectUnsupportedEnvironment(owner, dump, CreateWorkspace{.request_id = request_id++, .size = size, .name = "Rejected", .launch = launch});
    expectUnsupportedEnvironment(owner, dump, CreateTab{.request_id = request_id++, .workspace = root.location.workspace, .label = "Rejected", .size = size, .launch = launch});
    expectUnsupportedEnvironment(owner, dump, CreatePane{.request_id = request_id++, .location = root.location, .size = size, .launch = launch});
    expectUnsupportedEnvironment(owner, dump, LaunchTab{.request_id = request_id++, .workspace = root.location.workspace.id, .label = "Rejected", .size = size, .launch = launch});
    expectUnsupportedEnvironment(owner, dump, LaunchWorktree{.request_id = request_id++, .worktree = tracked.worktree, .label = "Rejected", .size = size, .launch = launch});
  }

  const Launch launch{.cwd = "/", .arguments = arguments};
  const auto split = owner.exchange<PaneOpened>(CreatePane{.request_id = request_id++, .location = root.location, .size = size, .launch = launch});
  owner.record(dump, split);
  const auto tab = owner.exchange<TabCreated>(CreateTab{.request_id = request_id++, .workspace = root.location.workspace, .label = "After failures", .size = size, .launch = launch});
  owner.record(dump, tab);
  const auto workspace = owner.exchange<PaneOpened>(CreateWorkspace{.request_id = request_id++, .size = size, .name = "After failures", .launch = launch});
  owner.record(dump, workspace);
  const auto worktree = owner.exchange<PaneOpened>(LaunchWorktree{.request_id = request_id++, .worktree = tracked.worktree, .label = "After failures", .size = size, .launch = launch});
  owner.record(dump, worktree);
}

static std::int64_t measureDefaultReuse(const char *socket, std::ostream &dump, std::size_t iterations) {
  ProtocolPeer owner{socket};
  OpenPane request{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}};
  const auto root = owner.exchange<PaneOpened>(request);
  PaneOpened reused;
  const auto reopen = [&] {
    ++request.request_id;
    reused = owner.exchange<PaneOpened>(request);
    check(!reused.created && reused.pane_id == root.pane_id && reused.pane_generation == root.pane_generation);
  };

  constexpr std::size_t warmup_iterations = 32;
  for (std::size_t index = 0; index < warmup_iterations; ++index) {
    reopen();
  }
  const auto started = std::chrono::steady_clock::now();
  for (std::size_t index = 0; index < iterations; ++index) {
    reopen();
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  owner.record(dump, reused);
  return elapsed / static_cast<std::int64_t>(iterations);
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }

  try {
    std::ofstream dump{argv[4], std::ios::binary};
    const auto started = std::chrono::steady_clock::now();
    const std::string_view workload{argv[2]};
    std::optional<std::int64_t> measured;
    if (workload == "launch-cwd") {
      checkAuthority(argv[1], dump);
      checkExitedSource(argv[1], dump);
    } else if (workload == "launch-default") {
      checkDefaultTab(argv[1], dump);
    } else if (workload == "launch-environment") {
      checkEnvironment(argv[1], dump);
    } else if (workload == "launch-reuse") {
      const auto iterations = std::strtoull(argv[3], nullptr, 10);
      check(iterations != 0);
      measured = measureDefaultReuse(argv[1], dump, iterations);
    } else {
      return 2;
    }
    const auto elapsed = measured.value_or(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count());
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
