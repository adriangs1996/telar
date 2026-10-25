#include "check.hpp"
#include "protocol_peer.hpp"
#include <algorithm>
#include <chrono>
#include <csignal>
#include <filesystem>
#include <thread>

using namespace telar;

static constexpr TerminalSize size{80, 24, 0, 0};
static constexpr std::array<std::string_view, 1> arguments{"/bin/cat"};

static void awaitText(ProtocolPeer &peer, const PaneOpened &pane, std::string_view expected) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    const auto text = peer.exchange<PaneText>(ReadPane{.request_id = 10, .pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = 24, .source = PaneTextSource::screen});
    if (text.text.contains(expected)) {
      return;
    }
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static void recordClosed(ProtocolPeer &peer, std::ostream &dump, const PaneOpened &pane, bool last) {
  auto closed = peer.receive<TabClosed>();
  check(closed.request_id == 0 && closed.location.workspace.id == pane.location.workspace.id && closed.location.tab_id == pane.location.tab_id);
  check(closed.workspace_closed == last);
  closed.location.workspace.id = 2;
  closed.location.tab_id = last ? 3 : 2;
  if (closed.previous_workspace) {
    closed.previous_workspace = 1;
  }
  peer.record(dump, closed);
}

static void checkForget(const char *socket, std::ostream &dump) {
  ProtocolPeer control{socket};
  ProtocolPeer observer{socket};
  const auto root = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Root", .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto registered = control.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = 2, .source = root.location.workspace.id, .path = "/tmp", .branch = "probe"});
  const std::array<std::string_view, 3> printing{"/bin/sh", "-c", "printf 'retained final output\\n'; exec /bin/cat"};
  const auto first = control.exchange<PaneOpened>(LaunchWorktree{.request_id = 3, .worktree = registered.worktree, .label = "First", .size = size, .launch = {.cwd = "/tmp", .arguments = printing}});
  const auto second = control.exchange<PaneOpened>(LaunchWorktree{.request_id = 4, .worktree = registered.worktree, .label = "Second", .size = size, .launch = {.cwd = "/tmp", .arguments = arguments}});
  observer.exchange<PaneOpened>(OpenPane{.request_id = 5, .target = {.kind = PaneTarget::Kind::pane, .id = first.pane_id}, .size = size});
  observer.exchange<PaneOpened>(OpenPane{.request_id = 6, .target = {.kind = PaneTarget::Kind::pane, .id = second.pane_id}, .size = size});
  awaitText(control, first, "retained final output");
  control.send(ForgetWorktree{.request_id = 7, .worktree = registered.worktree});
  recordClosed(observer, dump, first, false);
  recordClosed(observer, dump, second, true);
  control.record(dump, control.receive<RequestCompleted>());

  const auto first_exit = observer.receive<PaneExited>();
  const auto second_exit = observer.receive<PaneExited>();
  check(first_exit.pane_id != second_exit.pane_id);
  check((first_exit.pane_id == first.pane_id || first_exit.pane_id == second.pane_id) && (second_exit.pane_id == first.pane_id || second_exit.pane_id == second.pane_id));
  check(first_exit.kind == ExitKind::signaled && second_exit.kind == ExitKind::signaled && first_exit.value == SIGKILL && second_exit.value == SIGKILL);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    auto text = control.exchange<PaneText>(ReadPane{.request_id = 8, .pane_id = first.pane_id, .pane_generation = first.pane_generation, .rows = 24, .source = PaneTextSource::recent});
    if (text.exit_code) {
      check(*text.exit_code == 128 + SIGKILL && text.text == "retained final output");
      text.pane_id = 2;
      control.record(dump, text);
      break;
    }
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  const auto missing = control.exchange<RequestFailed>(ForgetWorktree{.request_id = 9, .worktree = registered.worktree});
  check(missing.code == FailureCode::worktree_not_found && missing.message == "worktree not found");
  control.record(dump, missing);
}

static void recordLabel(const char *socket, std::ostream &dump, std::uint64_t identity, std::string_view expected) {
  ProtocolPeer reader{socket};
  reader.send(RequestRuntimeState{.client_identity = 91, .interactive = false});
  const auto list = reader.receive<WorkspaceList>();
  const auto found = std::ranges::find(list.worktrees, identity, &WorktreeListEntry::worktree);
  check(found != list.worktrees.end() && found->command_label == expected && found->command_state == CommandState::running);
  dump << found->command_label << '\n';
}

static void checkLabels(const char *socket, std::ostream &dump) {
  ProtocolPeer control{socket};
  const auto root = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Root", .launch = Launch{.cwd = "/", .arguments = arguments}});
  std::array<char, 64> pattern{};
  std::strcpy(pattern.data(), "/tmp/telar-command-label.XXXXXX");
  check(::mkdtemp(pattern.data()) != nullptr);
  const std::filesystem::path directory{pattern.data()};
  const std::string prefix(46, 'x');
  const auto executable = (directory / (prefix + "€more")).string();
  std::filesystem::create_symlink("/bin/cat", executable);
  const auto registered = control.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = 2, .source = root.location.workspace.id, .path = pattern.data(), .branch = "probe"});
  const std::array<std::string_view, 3> script{"/bin/sh", "-c", "exec /bin/cat"};
  const std::array<std::string_view, 6> wrapped{"/bin/sh", "-l", "-i", "-c", "exec \"$0\" \"$@\"", "/bin/cat"};
  const std::array<std::string_view, 1> long_program{executable};
  const std::array<std::span<const std::string_view>, 4> commands{arguments, script, wrapped, long_program};
  const std::array<std::string_view, 4> labels{"cat", "sh", "cat", prefix};
  for (std::size_t index = 0; index < commands.size(); ++index) {
    control.exchange<PaneOpened>(LaunchWorktree{.request_id = 3, .worktree = registered.worktree, .size = size, .launch = {.cwd = "/tmp", .arguments = commands[index]}});
    recordLabel(socket, dump, registered.worktree, labels[index]);
  }
  control.exchange<RequestCompleted>(ForgetWorktree{.request_id = 4, .worktree = registered.worktree});
  std::filesystem::remove_all(directory);
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    const auto started = std::chrono::steady_clock::now();
    std::ofstream dump{argv[4], std::ios::binary};
    const std::string_view workload{argv[2]};
    if (workload == "worktree-forget") {
      checkForget(argv[1], dump);
    } else if (workload == "worktree-labels") {
      checkLabels(argv[1], dump);
    } else {
      return 2;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", elapsed);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "worktree-lifecycle-probe: %s\n", error.what());
    return 1;
  }
}
