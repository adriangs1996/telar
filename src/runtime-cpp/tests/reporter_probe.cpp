#include <sys/wait.h>
#include <cerrno>
#include <cstdio>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.runtime.tests.agent_oracle;

using namespace telar;

struct ReporterCase {
  const char *socket;
  const char *dump_path;
  const char *result_path;
  std::string_view workload;
  unsigned iterations;
  std::uint64_t pane;
  std::uint64_t generation;
};

static void require(bool valid, const char *message) {
  if (!valid) {
    throw std::runtime_error{message};
  }
}

static void waitProvider(ProtocolPeer &peer, AgentProvider provider) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (std::chrono::steady_clock::now() < deadline) {
    const auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{1});
    if (snapshot.entries.size() == 1 && snapshot.entries[0].provider == provider) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  throw std::runtime_error{"Reporter fixture provider was not identified"};
}

static void writeDuration(const ReporterCase &fixture, std::chrono::steady_clock::time_point started) {
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{fixture.result_path} << "{\"iterations\":" << fixture.iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / fixture.iterations << "}\n";
}

static void sendReport(ProtocolPeer &peer, const ReporterCase &fixture, std::uint64_t request) {
  if (fixture.workload == "reporter-replace-title") {
    peer.send(ReportAgentTitle{.request_id = request, .pane_id = fixture.pane, .pane_generation = fixture.generation, .provider = AgentProvider::claude, .title = "Replacement title"});
  } else if (fixture.workload == "reporter-replace-progress") {
    peer.send(ReportAgentProgress{.request_id = request, .pane_id = fixture.pane, .pane_generation = fixture.generation, .provider = AgentProvider::claude, .final_message = "Replacement progress"});
  } else if (fixture.workload == "reporter-replace-command") {
    peer.send(ReportAgentCommand{.request_id = request, .pane_id = fixture.pane, .pane_generation = fixture.generation, .phase = AgentCommandPhase::started, .provider = "claude", .tool_call_id = "replacement", .command = "printf replacement", .cwd = "/tmp"});
  } else {
    peer.send(ReportAgent{.request_id = request, .pane_id = fixture.pane, .pane_generation = fixture.generation, .provider = AgentProvider::claude, .state = AgentReportState::working, .event = "Replacement work"});
  }
}

static int replacement(const ReporterCase &fixture) {
  ProtocolPeer peer{fixture.socket};
  std::ofstream dump{fixture.dump_path, std::ios::binary | std::ios::app};
  const auto started = std::chrono::steady_clock::now();
  peer.exchange<RequestCompleted>(VerifyPaneDescent{2, fixture.pane, fixture.generation});
  sendReport(peer, fixture, 3);
  peer.send(QueryAgents{4});
  require(peer.receive<RequestCompleted>().request_id == 3, "Deferred report completed out of order");
  const auto snapshot = peer.receive<AgentSnapshot>();
  require(snapshot.entries.size() == 1 && snapshot.entries[0].provider == AgentProvider::claude, "Replacement report was not applied before the queued query");
  recordAgents(peer, dump);

  for (unsigned index = 1; index < fixture.iterations; ++index) {
    sendReport(peer, fixture, 3);
    require(peer.receive<RequestCompleted>().request_id == 3, "Replacement report was not accepted");
    recordAgents(peer, dump);
  }
  writeDuration(fixture, started);
  return 0;
}

static int nested(const ReporterCase &fixture) {
  ProtocolPeer peer{fixture.socket};
  std::ofstream dump{fixture.dump_path, std::ios::binary | std::ios::app};
  const auto started = std::chrono::steady_clock::now();
  peer.exchange<RequestCompleted>(VerifyPaneDescent{2, fixture.pane, fixture.generation});
  for (unsigned index = 0; index < fixture.iterations; ++index) {
    sendReport(peer, fixture, 3);
    auto failure = peer.receive<RequestFailed>();
    require(failure.request_id == 3 && failure.code == FailureCode::foreign_process, "A nested agent reported for the pane's agent");
    failure.message = {};
    peer.record(dump, failure);
  }
  writeDuration(fixture, started);
  return 0;
}

static int child(int argc, char **argv) {
  require(argc == 7, "Invalid reporter child arguments");
  const ReporterCase fixture{argv[2], argv[3], argv[4], argv[5], static_cast<unsigned>(std::stoul(argv[6])), std::stoull(std::getenv("TELAR_PANE_ID")), std::stoull(std::getenv("TELAR_PANE_GENERATION"))};
  const auto executable = std::filesystem::path{argv[0]};
  if (executable.filename() == "claude") {
    return fixture.workload == "reporter-nested" ? nested(fixture) : replacement(fixture);
  }

  ProtocolPeer peer{fixture.socket};
  constexpr std::string_view output = "\x1b[2J\x1b[H";
  require(::write(STDOUT_FILENO, output.data(), output.size()) == static_cast<ssize_t>(output.size()), "Cannot initialize reporter terminal");
  waitProvider(peer, AgentProvider::codex);
  {
    std::ofstream dump{fixture.dump_path, std::ios::binary};
    recordAgents(peer, dump);
  }

  const auto claude = (executable.parent_path() / "claude").string();
  argv[0] = const_cast<char *>(claude.c_str());
  if (fixture.workload != "reporter-nested") {
    ::execv(claude.c_str(), argv);
    throw std::runtime_error{"Cannot replace the fixture agent"};
  }

  const pid_t process = ::fork();
  require(process >= 0, "Cannot fork nested fixture");
  if (process == 0) {
    std::array<char *, 12> shell_arguments{const_cast<char *>("/bin/sh"), const_cast<char *>("-c"), const_cast<char *>("\"$@\" & wait"), const_cast<char *>("fixture")};
    std::copy(argv, argv + argc, shell_arguments.begin() + 4);
    ::execv(shell_arguments[0], shell_arguments.data());
    ::_exit(127);
  }

  int status = 0;
  pid_t waited;
  do {
    waited = ::waitpid(process, &status, 0);
  } while (waited < 0 && errno == EINTR);
  require(waited == process && WIFEXITED(status) && WEXITSTATUS(status) == 0, "Nested fixture failed");
  std::ofstream dump{fixture.dump_path, std::ios::binary | std::ios::app};
  recordAgents(peer, dump);
  return 0;
}

int main(int argc, char **argv) {
  const bool is_child = argc >= 2 && std::string_view{argv[1]} == "--reporter-child";
  try {
    if (is_child) {
      return child(argc, argv);
    }
    if (argc != 5) {
      return 2;
    }

    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const auto codex = (root / "codex").string();
    const auto result_path = (root / "reporter-result.json").string();
    std::filesystem::copy_file(argv[0], codex);
    std::filesystem::copy_file(argv[0], root / "claude");
    const std::array<std::string_view, 7> arguments{codex, "--reporter-child", argv[1], argv[4], result_path, argv[2], argv[3]};
    ProtocolPeer peer{argv[1]};
    const auto directory = std::filesystem::canonical("/tmp").string();
    peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = directory, .arguments = arguments}});
    const auto exited = peer.receive<PaneExited>();
    std::ifstream result{result_path};
    if (exited.kind != ExitKind::exited || exited.value != 0 || !result.good()) {
      std::cerr << result.rdbuf();
      return 1;
    }

    std::cout << result.rdbuf();
    return 0;
  } catch (const std::exception &error) {
    if (is_child && argc == 7) {
      std::ofstream{argv[4]} << error.what() << '\n';
    }
    std::fprintf(stderr, "reporter-probe: %s\n", error.what());
    return 1;
  }
}
