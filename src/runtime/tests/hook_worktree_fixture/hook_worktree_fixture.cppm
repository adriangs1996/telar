module;
#include <csignal>

export module telar.runtime.tests.hook_worktree_fixture;

import std;
export import telar.runtime.tests.hook_fixture;

export {
namespace hook_fixture {

inline std::string createRepository(const std::filesystem::path &directory) {
  using namespace telar::runtime;
  std::filesystem::create_directory(directory);
  const auto path = directory.string();
  telar::SystemAllocator memory;
  CommandOutput output{memory, 4096};
  const std::array<std::string_view, 5> initialize{"git", "init", "-q", "-b", "main"};
  const std::array<std::string_view, 14> commit{"git", "-c", "user.name=Hook Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "Fixture", "--"};
  for (const std::span<const std::string_view> arguments : {std::span<const std::string_view>{initialize}, std::span<const std::string_view>{commit}}) {
    Command command{memory, telar::Launch{.cwd = path, .arguments = arguments}, CommandPurpose::configured_helper};
    require(output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}) == 0, "Cannot initialize hook repository");
  }

  return path;
}

inline std::uint64_t registeredWorktree(const char *socket, std::string_view path, std::ostream &dump) {
  using namespace telar;
  ProtocolPeer reader{socket};
  reader.send(RequestRuntimeState{.client_identity = 741, .interactive = false});
  const auto catalog = reader.receive<WorkspaceList>();
  require(catalog.worktrees.size() == 1, "Hook did not register exactly one worktree");
  const auto &entry = catalog.worktrees.front();
  require(entry.path == path && entry.branch == "hook-branch" && entry.base == "main", "Hook registered different worktree metadata");
  require(entry.created_by.has_value() && entry.source != 0, "Hook registration lost its source pane or workspace");
  dump << "registered " << entry.branch << ' ' << entry.base << ' ' << static_cast<unsigned>(entry.origin) << '\n';
  dump.flush();
  return entry.worktree;
}

inline void requireForgotten(const char *socket) {
  ProtocolPeer reader{socket};
  reader.send(telar::RequestRuntimeState{.client_identity = 742, .interactive = false});
  const auto catalog = reader.receive<telar::WorkspaceList>();
  require(catalog.worktrees.empty() && catalog.entries.size() == 1, "Hook did not forget the worktree and its workspace");
}

inline void waitWorktreeOutput(ProtocolPeer &peer, std::uint64_t pane) {
  using namespace telar;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    const auto output = peer.exchange<PaneText>(ReadPane{.request_id = 24, .pane_id = pane, .rows = 24});
    if (output.text.contains("worktree-visible")) {
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Worktree pane did not produce output"};
}

inline void exerciseWorktreeHooks(ProtocolPeer &peer, const char *socket, std::ostream &dump, bool dirty) {
  using namespace telar;
  const auto directory = std::filesystem::current_path().string();
  const auto create = std::string{R"({"hook_event_name":"WorktreeCreate","name":"hook-branch","cwd":")"} + directory + "\"}";
  auto path = runHook("claude", create, true);
  require(path.ends_with('\n'), "Worktree hook did not return a checkout path");
  path.pop_back();
  require(std::filesystem::is_directory(path), "Worktree hook checkout does not exist");
  const auto worktree = registeredWorktree(socket, path, dump);
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf 'worktree-visible\\n'; exec /bin/cat"};
  const auto opened = peer.exchange<PaneOpened>(LaunchWorktree{.request_id = 23, .worktree = worktree, .label = "Hook checkout", .size = {80, 24, 0, 0}, .launch = {.cwd = path, .arguments = arguments}});
  peer.exchange<PaneOpened>(OpenPane{.request_id = 25, .target = {.kind = PaneTarget::Kind::pane, .id = opened.pane_id}, .size = {80, 24, 0, 0}});
  waitWorktreeOutput(peer, opened.pane_id);
  dump << "launched\n"
       << std::flush;
  if (dirty) {
    std::ofstream{std::filesystem::path{path} / "local.txt"} << "Retain this work\n";
  }

  const auto payload = std::string{R"({"hook_event_name":"WorktreeRemove","worktree_path":")"} + path + "\"}";
  require(runHook("claude", payload).empty(), "Worktree removal unexpectedly wrote stdout");
  dump << "removed\n"
       << std::flush;
  const auto exited = peer.receive<PaneExited>();
  require(exited.pane_id == opened.pane_id && exited.kind == ExitKind::signaled && exited.value == SIGKILL, "Worktree hook did not stop the checkout process");
  requireForgotten(socket);
  require(std::filesystem::exists(path) == dirty, "Hook did not preserve the expected checkout state");
  if (dirty) {
    std::ifstream contents{std::filesystem::path{path} / "local.txt"};
    std::string line;
    std::getline(contents, line);
    require(line == "Retain this work", "Hook modified local work");
  }

  dump << "forgotten " << dirty << ' ' << exited.value << '\n';
}

}
}
