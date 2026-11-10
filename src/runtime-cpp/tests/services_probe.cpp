
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
import std;
import telar.runtime.tests.agent_oracle;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static void require(bool value) {
  if (!value) {
    throw SocketError{"Service oracle assertion failed"};
  }
}

static PaneOpened openPane(ProtocolPeer &peer) {
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const auto directory = std::filesystem::canonical("/tmp").string();
  auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 1,
                                                   .size = {80, 24, 8, 16},
                                                   .launch = Launch{.cwd = directory,
                                                                    .arguments = arguments}});
  peer.send(DetachPane{opened.pane_id});
  return opened;
}

static ExecutionReply execution(ProtocolPeer &peer, const ExecutionRequest &request) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  for (;;) {
    try {
      return peer.exchange<ExecutionReply>(request);
    } catch (const ProtocolFailure &failure) {
      if (std::string_view{failure.what()} != "ExecutionBusy" || std::chrono::steady_clock::now() >= deadline) {
        throw;
      }
    }
  }
}

static void executions(ProtocolPeer &peer, unsigned iterations, std::ostream &dump) {
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf output; printf error >&2; exit 7"};
  for (unsigned index = 1; index <= iterations; ++index) {
    const auto identity = static_cast<std::uint64_t>(index);
    auto reply = execution(peer, ExecutionRequest{.request_id = identity,
                                                  .action = ExecutionAction::start,
                                                  .execution_id = identity,
                                                  .cwd = "/tmp",
                                                  .arguments = arguments});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
    while (reply.state == ExecutionState::starting || reply.state == ExecutionState::running) {
      require(std::chrono::steady_clock::now() < deadline);
      reply = execution(peer, ExecutionRequest{.request_id = identity,
                                               .action = ExecutionAction::status,
                                               .execution_id = identity});
    }
    require(reply.exit_code == 7 && reply.stdout_total == 6 && reply.stderr_total == 5);
    reply.workspace_id = 1;
    peer.record(dump, reply);
    execution(peer, ExecutionRequest{.request_id = identity,
                                     .action = ExecutionAction::forget,
                                     .execution_id = identity});
  }
}

static void limits(ProtocolPeer &peer, unsigned iterations, std::ostream &dump) {
  peer.send(ReportLimit{.reach = {.name = "probe.capacity",
                                  .noun = "items",
                                  .value = 16,
                                  .requested = 17,
                                  .route = "probe"},
                        .hits = 3});
  for (unsigned index = 1; index <= iterations; ++index) {
    auto result = peer.exchange<LimitList>(QueryLimits{index});
    require(result.entries.size() == 1 && result.entries[0].hits == 3);
    auto entry = result.entries[0];
    entry.last_ms = 0;
    result.entries = std::span{&entry, 1};
    peer.record(dump, result);
  }
}

static void paths(ProtocolPeer &peer, unsigned iterations, std::ostream &dump) {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-path-probe.XXXXXX");
  require(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  std::filesystem::create_directories(root / "src" / "tests");
  std::filesystem::create_directories(root / "docs");
  std::ofstream{root / "src" / "runtime.cpp"} << "fixture";
  std::ofstream{root / "src" / "tests" / "RuntimeTest.cpp"} << "fixture";
  std::ofstream{root / "docs" / "runtime.md"} << "fixture";
  std::ofstream{root / "README.md"} << "fixture";
  constexpr std::array<std::string_view, 4> queries{"", "rt", "src", "md"};
  for (unsigned index = 0; index < iterations; ++index) {
    const FindPaths request{.request_id = index + 1,
                            .root = directory.data(),
                            .query = queries[index % queries.size()],
                            .limit = 50};
    auto result = peer.exchange<PathResults>(request);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
    while (!result.complete) {
      require(std::chrono::steady_clock::now() < deadline);
      result = peer.receive<PathResults>();
    }
    result.root = "/fixture";
    peer.record(dump, result);
  }
  std::filesystem::remove_all(root);
}

static void worktrees(ProtocolPeer &peer, unsigned iterations, std::ostream &dump) {
  const auto root = openPane(peer);
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  for (unsigned index = 1; index <= iterations; ++index) {
    auto registered = peer.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = index,
                                                                         .source = root.location.workspace.id,
                                                                         .path = "/tmp",
                                                                         .branch = "probe",
                                                                         .title = "Probe worktree"});
    const auto identity = registered.worktree;
    registered.worktree = 1;
    peer.record(dump, registered);
    auto repeated = peer.exchange<WorktreeRegistered>(RegisterWorktree{.request_id = index,
                                                                       .source = root.location.workspace.id,
                                                                       .path = "/tmp",
                                                                       .branch = "probe",
                                                                       .title = "Updated title"});
    require(repeated.worktree == identity && !repeated.created);
    repeated.worktree = 1;
    peer.record(dump, repeated);
    auto pane = peer.exchange<PaneOpened>(LaunchWorktree{.request_id = index,
                                                         .worktree = identity,
                                                         .label = "first",
                                                         .size = {80, 24, 8, 16},
                                                         .launch = {.cwd = "/tmp",
                                                                    .arguments = arguments}});
    const auto workspace = pane.location.workspace;
    pane.pane_id = 2;
    pane.pane_generation = 1;
    pane.location = {.workspace = {.id = 2},
                     .tab_id = 2};
    peer.record(dump, pane);
    auto second = peer.exchange<PaneOpened>(LaunchTab{.request_id = index,
                                                      .workspace = workspace.id,
                                                      .label = "second",
                                                      .size = {80, 24, 8, 16},
                                                      .launch = {.cwd = "/tmp",
                                                                 .arguments = arguments}});
    second.pane_id = 3;
    second.pane_generation = 1;
    second.location = {.workspace = {.id = 2},
                       .tab_id = 3};
    peer.record(dump, second);
    const auto snapshot = peer.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = index,
                                                                                    .workspace = workspace});
    require(snapshot.tabs.size() == 2);
    peer.record(dump, peer.exchange<RequestCompleted>(ForgetWorktree{.request_id = index,
                                                                     .worktree = identity}));
  }
}

static void agents(ProtocolPeer &peer, unsigned iterations, std::ostream &dump) {
  const auto pane = openPane(peer);
  try {
    peer.exchange<RequestCompleted>(VerifyPaneDescent{.request_id = 1,
                                                      .pane_id = pane.pane_id,
                                                      .pane_generation = pane.pane_generation});
    throw SocketError{"Foreign process passed descent verification"};
  } catch (const ProtocolFailure &failure) {
    require(failure.code == FailureCode::foreign_process);
  }
  for (unsigned index = 1; index <= iterations; ++index) {
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentSession{.request_id = index,
                                                                         .pane_id = pane.pane_id,
                                                                         .pane_generation = pane.pane_generation,
                                                                         .session = "fixture-session"}));
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgent{.request_id = index,
                                                                  .pane_id = pane.pane_id,
                                                                  .pane_generation = pane.pane_generation,
                                                                  .state = AgentReportState::working,
                                                                  .event = "Editing"}));
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentTitle{.request_id = index,
                                                                       .pane_id = pane.pane_id,
                                                                       .pane_generation = pane.pane_generation,
                                                                       .title = "Runtime fixture"}));
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgentProgress{.request_id = index,
                                                                          .pane_id = pane.pane_id,
                                                                          .pane_generation = pane.pane_generation,
                                                                          .final_message = "Finished fixture",
                                                                          .plan_op = AgentPlanOp::set,
                                                                          .plan_done = 1,
                                                                          .plan_total = 2,
                                                                          .plan_text = "Validate"}));
    recordAgents(peer, dump);
    peer.record(dump, peer.exchange<RequestCompleted>(ReportAgent{.request_id = index,
                                                                  .pane_id = pane.pane_id,
                                                                  .pane_generation = pane.pane_generation,
                                                                  .state = AgentReportState::ready,
                                                                  .event = "Finished"}));
    recordAgents(peer, dump);
    peer.send(AcknowledgeAgent{pane.pane_id, pane.pane_generation});
    recordAgents(peer, dump);
  }
}

static void editorAndSuggestions(ProtocolPeer &peer, unsigned iterations, std::ostream &dump, bool editor) {
  const auto pane = openPane(peer);
  for (unsigned index = 1; index <= iterations; ++index) {
    if (editor) {
      auto opened = peer.exchange<EditorOpened>(OpenEditor{.request_id = index,
                                                           .pane_id = pane.pane_id,
                                                           .pane_generation = pane.pane_generation,
                                                           .editor = "nvim",
                                                           .path = "/nonexistent-telar-editor-probe",
                                                           .line = 1});
      require(opened.outcome == EditorOutcome::missing || opened.outcome == EditorOutcome::failed);
      opened.pane_id = 0;
      opened.pane_generation = 0;
      peer.record(dump, opened);
    } else {
      peer.record(dump, peer.exchange<CommandSuggestion>(SuggestCommand{.request_id = index,
                                                                        .pane_id = pane.pane_id,
                                                                        .text = "show git status"}));
    }
  }
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    ProtocolPeer peer{argv[1]};
    const std::string_view workload{argv[2]};
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    std::ofstream dump{argv[4], std::ios::binary};
    const auto started = std::chrono::steady_clock::now();
    if (workload == "executions") {
      executions(peer, iterations, dump);
    } else if (workload == "agents") {
      agents(peer, iterations, dump);
    } else if (workload == "limits") {
      limits(peer, iterations, dump);
    } else if (workload == "paths") {
      paths(peer, iterations, dump);
    } else if (workload == "worktrees") {
      worktrees(peer, iterations, dump);
    } else if (workload == "editor" || workload == "suggestions") {
      editorAndSuggestions(peer, iterations, dump, workload == "editor");
    } else {
      throw SocketError{"Unknown service workload"};
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%lld}\n", iterations, static_cast<long long>(elapsed), static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "services-probe: %s\n", error.what());
    return 1;
  }
}
