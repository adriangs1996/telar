#include "agent_oracle.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <libproc.h>
#include <thread>

using namespace telar;

static constexpr std::string_view missing_hooks_event = "no hooks from this pane: if it runs on a shared server, start it with --no-daemon";

static int checkProcessName(ProtocolPeer &peer, char **arguments) {
  proc_bsdinfo information{};
  if (::proc_pidinfo(::getpid(), PROC_PIDTBSDINFO, 0, &information, sizeof(information)) != sizeof(information)) {
    throw std::runtime_error{"Cannot inspect fixture process name"};
  }
  const std::string_view expected{information.pbi_comm, ::strnlen(information.pbi_comm, sizeof(information.pbi_comm))};
  const auto started = std::chrono::steady_clock::now();
  peer.send(RequestRuntimeState{.client_identity = 1, .interactive = false});
  for (;;) {
    auto foreground = peer.receive<PaneForeground>();
    if (foreground.name == expected) {
      std::ofstream dump{arguments[3], std::ios::binary};
      foreground.pane_id = 1;
      peer.record(dump, foreground);
      break;
    }
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{arguments[4]} << "{\"iterations\":1,\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed << "}\n";
  return 0;
}

static void paint(std::string_view text) {
  while (!text.empty()) {
    const auto count = ::write(STDOUT_FILENO, text.data(), text.size());
    if (count <= 0) {
      throw std::runtime_error{"Cannot paint process fixture"};
    }

    text.remove_prefix(static_cast<std::size_t>(count));
  }
}

static AgentSnapshotEntry waitState(ProtocolPeer &peer, AgentStatus status, AgentSource source, std::string_view event = {}) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{7};
  while (std::chrono::steady_clock::now() < deadline) {
    const auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{1});
    if (snapshot.entries.size() == 1) {
      const auto &agent = snapshot.entries[0];
      if (agent.provider == AgentProvider::codex && agent.status == status && agent.source == source && agent.last_event == event) {
        if (agent.process_id != static_cast<std::uint32_t>(::getpgrp())) {
          throw std::runtime_error{"Agent projection lost its foreground process group"};
        }
        return agent;
      }
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }

  throw std::runtime_error{"Process fixture did not reach its expected agent state"};
}

static int child(char **arguments) {
  const auto pane = std::stoull(std::getenv("TELAR_PANE_ID"));
  const auto generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
  const auto iterations = static_cast<unsigned>(std::stoul(arguments[2]));
  const std::string_view workload{arguments[5]};
  ProtocolPeer peer{arguments[1]};
  paint("\x1b[2J\x1b[H");
  if (workload == "process-name") {
    return checkProcessName(peer, arguments);
  }
  waitState(peer, AgentStatus::unknown, AgentSource::foreground_process);
  std::ofstream dump{arguments[3], std::ios::binary};
  recordAgents(peer, dump);
  const auto started = std::chrono::steady_clock::now();
  if (workload == "process-shared-warning" || workload == "process-no-daemon" || workload == "process-batch") {
    paint("\x1b[20;1HWorking (1s)\x1b[22;1H› Ask Codex to do anything\x1b[22;3H");
    waitState(peer, AgentStatus::working, AgentSource::screen);
    recordAgents(peer, dump);
    if (workload == "process-shared-warning") {
      waitState(peer, AgentStatus::working, AgentSource::screen, missing_hooks_event);
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds{5300});
      waitState(peer, AgentStatus::working, AgentSource::screen);
    }

    recordAgents(peer, dump);
    paint("\x1b[20;1H\x1b[2K\x1b[22;3H");
    waitState(peer, AgentStatus::done, AgentSource::screen);
    recordAgents(peer, dump);
  }

  peer.exchange<RequestCompleted>(VerifyPaneDescent{2, pane, generation});
  for (unsigned iteration = 0; iteration < iterations; ++iteration) {
    peer.exchange<RequestCompleted>(ReportAgent{.request_id = 3, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .state = AgentReportState::working, .event = "Official work"});
    recordAgents(peer, dump);
    peer.exchange<RequestCompleted>(ReportAgent{.request_id = 4, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::codex, .state = AgentReportState::ready, .event = "Official completion"});
    recordAgents(peer, dump);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{arguments[4]} << "{\"iterations\":" << iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / iterations << "}\n";
  return 0;
}

int main(int argc, char **argv) {
  char **child_arguments = nullptr;
  try {
    for (int index = 1; index + 6 <= argc; ++index) {
      if (index + 6 == argc && std::string_view{argv[index]} == "--process-child") {
        child_arguments = argv + index;
        return child(child_arguments);
      }
    }
    if (argc != 5) {
      return 2;
    }

    const std::string_view workload{argv[2]};
    const bool node = workload == "process-node";
    const bool group = workload == "process-group";
    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const auto executable = (root / (node ? "node" : workload == "process-name" ? "unknown_process_with_a_long_name"
                                                                                : "codex"))
                                .string();
    const auto result_path = (root / "process-result.json").string();
    std::filesystem::copy_file(argv[0], executable);
    const char *configured_home = std::getenv("CODEX_HOME");
    if (configured_home == nullptr || std::filesystem::weakly_canonical(std::filesystem::path{configured_home}.parent_path()) != std::filesystem::canonical(root)) {
      throw std::runtime_error{"Process fixture requires an isolated CODEX_HOME"};
    }

    std::filesystem::create_directory(configured_home);
    if (workload == "process-shared-warning" || workload == "process-no-daemon" || workload == "process-batch") {
      std::ofstream{std::filesystem::path{configured_home} / "hooks.json"} << "{\"command\":\"telar hook codex\"}";
    }

    std::vector<std::string_view> arguments;
    if (group) {
      arguments = {"/bin/sh", "-c", "\"$@\" & wait", "fixture"};
    }
    arguments.push_back(executable);
    if (node) {
      arguments.push_back("--trace-warnings");
      arguments.push_back("/fixture/@openai/codex/cli.js");
    } else if (workload == "process-no-daemon") {
      arguments.push_back("--no-daemon");
    } else if (workload == "process-batch") {
      arguments.push_back("exec");
    }

    arguments.insert(arguments.end(), {"--process-child", argv[1], argv[3], argv[4], result_path, argv[2]});
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
    if (child_arguments != nullptr) {
      std::ofstream{child_arguments[4]} << error.what() << '\n';
    }
    std::fprintf(stderr, "process-probe: %s\n", error.what());
    return 1;
  }
}
