#include "agent_oracle.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <poll.h>
#include <source_location>
#include <termios.h>

static std::string_view operation;

static void require(bool value, std::source_location location = std::source_location::current()) {
  if (!value) {
    throw std::runtime_error{"Agent oracle assertion at line " + std::to_string(location.line())};
  }
}

static int agentChild(char **arguments) {
  termios terminal{};
  require(::tcgetattr(STDIN_FILENO, &terminal) == 0);
  ::cfmakeraw(&terminal);
  require(::tcsetattr(STDIN_FILENO, TCSANOW, &terminal) == 0);
  ProtocolPeer peer{arguments[2]};
  const auto pane = std::stoull(std::getenv("TELAR_PANE_ID"));
  const auto generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
  const auto iterations = static_cast<unsigned>(std::stoul(arguments[3]));
  std::ofstream dump{arguments[4], std::ios::binary};
  operation = "verify";
  peer.exchange<RequestCompleted>(VerifyPaneDescent{.request_id = 1,
                                                    .pane_id = pane,
                                                    .pane_generation = generation});
  ProtocolPeer history_peer{arguments[2]};
  ProtocolPeer controller{arguments[2]};
  const auto started = std::chrono::steady_clock::now();
  for (unsigned index = 1; index <= iterations; ++index) {
    operation = "session";
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentSession{.request_id = index,
                                                                         .pane_id = pane,
                                                                         .pane_generation = generation,
                                                                         .session = "fixture-session"}));
    operation = "report";
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgent{.request_id = index,
                                                                  .pane_id = pane,
                                                                  .pane_generation = generation,
                                                                  .provider = AgentProvider::claude,
                                                                  .state = AgentReportState::working,
                                                                  .event = "Editing"}));
    operation = "title";
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentTitle{.request_id = index,
                                                                       .pane_id = pane,
                                                                       .pane_generation = generation,
                                                                       .provider = AgentProvider::claude,
                                                                       .title = "Runtime fixture"}));
    operation = "progress";
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentProgress{.request_id = index,
                                                                          .pane_id = pane,
                                                                          .pane_generation = generation,
                                                                          .provider = AgentProvider::claude,
                                                                          .final_message = "Finished fixture",
                                                                          .plan_op = AgentPlanOp::set,
                                                                          .plan_done = 1,
                                                                          .plan_total = 2,
                                                                          .plan_text = "Validate"}));
    operation = "snapshot";
    recordAgents(peer, dump);

    const auto tool_call = std::to_string(index);
    ReportAgentCommand command{.request_id = index,
                               .pane_id = pane,
                               .pane_generation = generation,
                               .phase = AgentCommandPhase::started,
                               .provider = "claude",
                               .tool_call_id = tool_call,
                               .command = "printf fixture",
                               .cwd = "/tmp"};
    operation = "command";
    peer.record(dump, peer.exchange<RequestCompleted>(command));
    operation = "command";
    peer.record(dump, peer.exchange<RequestCompleted>(command));
    command.phase = AgentCommandPhase::finished;
    command.exit_code = 0;
    operation = "command";
    peer.record(dump, peer.exchange<RequestCompleted>(command));
    operation = "history";
    if (index > 1) {
      history_peer.reconnect(arguments[2]);
    }
    auto history = history_peer.exchange<HistoryResults>(QueryHistory{.request_id = index,
                                                                      .author = HistoryAuthorFilter::agent,
                                                                      .limit = 1});
    require(history.entries.size() == 1 && history.entries[0].command == command.command && history.entries[0].exit_code == 0);
    auto entry = history.entries[0];
    entry.pane_id = 1;
    entry.started_at_ms = 0;
    entry.duration_ns = 0;
    history.entries = std::span{&entry, 1};
    peer.record(dump, history);

    if (std::string_view{arguments[6]} == "agent-hooks-interrupt") {
      operation = "interrupt";

      peer.record(dump, controller.exchange<RequestCompleted>(InterruptAgent{.request_id = index,
                                                                             .pane_id = pane,
                                                                             .pane_generation = generation}));
      pollfd input{STDIN_FILENO, POLLIN, 0};
      require(::poll(&input, 1, 3000) == 1);
      char key = 0;
      require(::read(STDIN_FILENO, &key, 1) == 1 && key == '\x03');
    }
    operation = "report";
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgent{.request_id = index,
                                                                  .pane_id = pane,
                                                                  .pane_generation = generation,
                                                                  .provider = AgentProvider::claude,
                                                                  .state = AgentReportState::ready,
                                                                  .event = "Finished"}));
    operation = "snapshot";
    recordAgents(peer, dump);
    peer.send(AcknowledgeAgent{pane, generation});
    operation = "snapshot";
    recordAgents(peer, dump);
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream result{arguments[5]};
  result << "{\"iterations\":" << iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / iterations << "}\n";
  return 0;
}

int main(int argc, char **argv) {
  try {
    if (argc == 7 && std::string_view{argv[1]} == "--child") {
      return agentChild(argv);
    }
    if (argc != 5) {
      return 2;
    }
    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const auto executable = (root / "claude").string();
    const auto result_path = (root / "agent-result.json").string();
    std::filesystem::copy_file(argv[0], executable);
    ProtocolPeer peer{argv[1]};
    const auto cwd = std::filesystem::canonical("/tmp").string();
    const std::array<std::string_view, 7> arguments{executable, "--child", argv[1], argv[3], argv[4], result_path, argv[2]};
    peer.exchange<PaneOpened>(OpenPane{.request_id = 1,
                                       .size = {80, 24, 8, 16},
                                       .launch = Launch{.cwd = cwd,
                                                        .arguments = arguments}});
    const auto exited = peer.receive<PaneExited>();
    std::ifstream result{result_path};
    if (exited.kind != ExitKind::exited || exited.value != 0) {
      std::cerr << result.rdbuf();
    }
    require(exited.kind == ExitKind::exited && exited.value == 0);
    require(result.good());
    std::cout << result.rdbuf();
    return 0;
  } catch (const std::exception &error) {
    if (argc == 7) {
      std::ofstream{argv[5]} << operation << ": " << error.what() << "\n";
    }
    std::fprintf(stderr, "agent-probe: %s\n", error.what());
    return 1;
  }
}
