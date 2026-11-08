
#include <cstdio>
#include <sys/types.h>
#include <unistd.h>
import std;
import telar.runtime.tests.agent_oracle;
import telar.runtime.tests.hook_worktree_fixture;

using namespace telar;
using namespace telar::runtime;
using namespace hook_fixture;

static int child(char **arguments) {
  const auto provider = providerNamed(arguments[3]);
  ProtocolPeer peer{arguments[2]};
  constexpr std::string_view output = "\x1b[2J\x1b[H";
  require(::write(STDOUT_FILENO, output.data(), output.size()) == static_cast<ssize_t>(output.size()), "Cannot initialize hook terminal");
  waitProvider(peer, provider);
  std::ofstream dump{arguments[4], std::ios::binary};
  const auto started = std::chrono::steady_clock::now();
  const std::string_view workload{arguments[7]};
  if (workload == "hook-worktree" || workload == "hook-worktree-dirty") {
    exerciseWorktreeHooks(peer, arguments[2], dump, workload == "hook-worktree-dirty");
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::ofstream{arguments[5]} << "{\"iterations\":1,\"ns_per_iteration\":" << elapsed << "}\n";
    return 0;
  }

  std::string_view begin;
  std::string_view working;
  std::string_view stopped;
  switch (provider) {
  case AgentProvider::claude:
    begin = R"({"hook_event_name":"SessionStart","session_id":"fixture-session","session_title":"Hook fixture","cwd":"/tmp"})";
    working = R"({"hook_event_name":"PreToolUse","session_id":"fixture-session","tool_name":"Edit","tool_input":{"file_path":"main.cpp"}})";
    stopped = R"({"hook_event_name":"Stop","session_id":"fixture-session","last_assistant_message":"Finished fixture"})";
    break;
  case AgentProvider::codex:
    begin = R"({"hook_event_name":"SessionStart","session_id":"fixture-session","cwd":"/tmp"})";
    working = R"({"hook_event_name":"PreToolUse","session_id":"fixture-session","tool_name":"Edit","tool_input":{"file_path":"main.cpp"}})";
    stopped = R"({"hook_event_name":"PermissionRequest","session_id":"fixture-session","tool_name":"Edit","tool_input":{"file_path":"main.cpp"}})";
    break;
  case AgentProvider::pi:
    begin = R"({"event":"session_start","session_id":"fixture-session","name":"Hook fixture"})";
    working = R"({"event":"agent_start","session_id":"fixture-session"})";
    stopped = R"({"event":"ui_prompt_start","session_id":"fixture-session"})";
    break;
  case AgentProvider::cursor:
    begin = R"({"hook_event_name":"sessionStart","conversation_id":"fixture-session"})";
    working = R"({"hook_event_name":"preToolUse","conversation_id":"fixture-session","tool_name":"Edit","tool_input":{"file_path":"main.cpp"}})";
    stopped = R"({"hook_event_name":"stop","conversation_id":"fixture-session"})";
    break;
  case AgentProvider::opencode:
    begin = R"({"event":"load","session_id":"fixture-session"})";
    working = R"({"event":"tool.execute.before","session_id":"fixture-session","tool_name":"Edit","tool_input":{"file_path":"main.cpp"}})";
    stopped = R"({"event":"question.asked","session_id":"fixture-session","blocked":"question","tool_input":{"questions":[{"question":"Continue?"}]}})";
    break;
  default:
    throw std::runtime_error{"Unknown hook fixture provider"};
  }

  for (const auto payload : {begin, working, stopped}) {
    runHook(arguments[3], payload);
    const auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{2});
    require(snapshot.entries.size() == 1 && snapshot.entries[0].source == AgentSource::lifecycle_report, "Hook was not applied to its pane");
    recordAgents(peer, dump);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{arguments[5]} << "{\"iterations\":3,\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / 3 << "}\n";
  return 0;
}

int main(int argc, char **argv) {
  try {
    if (argc == 8 && std::string_view{argv[1]} == "--hook-child") {
      return child(argv);
    }
    if (argc != 5) {
      return 2;
    }

    const std::string_view workload{argv[2]};
    const bool worktree = workload == "hook-worktree" || workload == "hook-worktree-dirty";
    const auto provider = worktree ? "claude" : workload.substr(sizeof("hook-") - 1);
    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const auto executable = (root / (provider == "cursor" ? "cursor-agent" : std::string{provider})).string();
    const auto result_path = (root / "hook-result.json").string();
    std::filesystem::copy_file(argv[0], executable);
    const std::array<std::string_view, 8> arguments{executable, "--hook-child", argv[1], provider, argv[4], result_path, "--no-daemon", workload};
    ProtocolPeer peer{argv[1]};
    const auto cwd = worktree ? createRepository(root / "repository") : std::filesystem::canonical("/tmp").string();
    const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = cwd, .arguments = arguments}});
    auto exited = peer.receive<PaneExited>();
    while (exited.pane_id != opened.pane_id) {
      exited = peer.receive<PaneExited>();
    }
    std::ifstream result{result_path};
    if (exited.kind != ExitKind::exited || exited.value != 0 || !result.good()) {
      std::cerr << result.rdbuf();
      return 1;
    }

    std::cout << result.rdbuf();
    return 0;
  } catch (const std::exception &error) {
    if (argc >= 6) {
      std::ofstream{argv[5]} << error.what() << '\n';
    }
    if (argc == 5) {
      std::ifstream observations{argv[4], std::ios::binary};
      std::cerr << observations.rdbuf();
      std::ifstream child_result{std::filesystem::path{argv[4]}.parent_path() / "hook-result.json"};
      std::cerr << child_result.rdbuf();
    }

    std::fprintf(stderr, "hook-probe: %s\n", error.what());
    return 1;
  }
}
