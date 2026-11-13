
#include <unistd.h>
#include <cstdio>
import std;
import telar.runtime.tests.agent_oracle;

using namespace telar;

static ProtocolPeer *notifications = nullptr;

static void paint(std::string_view text) {
  while (!text.empty()) {
    const auto count = ::write(STDOUT_FILENO, text.data(), text.size());
    if (count <= 0) {
      throw std::runtime_error{"Cannot draw agent screen"};
    }
    text.remove_prefix(count);
  }
}

static void waitState(ProtocolPeer &peer, AgentStatus status, AgentSource source, bool use_notifications = true) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    const auto snapshot = notifications != nullptr && use_notifications ? notifications->receive<AgentSnapshot>() : peer.exchange<AgentSnapshot>(QueryAgents{1});
    if (snapshot.entries.size() == 1 && snapshot.entries[0].status == status && snapshot.entries[0].source == source) {
      return;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error{"Agent screen did not reach expected state " + std::to_string(static_cast<int>(status)) + " source " + std::to_string(static_cast<int>(source)) + "; last " + (snapshot.entries.empty() ? std::string{"empty"} : std::to_string(static_cast<int>(snapshot.entries[0].status)) + " source " + std::to_string(static_cast<int>(snapshot.entries[0].source)))};
    }
    if (notifications == nullptr || !use_notifications) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }
}

static int child(char **arguments) {
  ProtocolPeer peer{arguments[2]};
  const auto pane = std::stoull(std::getenv("TELAR_PANE_ID"));
  const auto generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
  const auto iterations = static_cast<unsigned>(std::stoul(arguments[3]));
  const std::string_view workload{arguments[6]};
  const bool codex = workload.starts_with("screen-codex");
  const bool cursor = workload.starts_with("screen-cursor");
  const bool custom = workload.starts_with("screen-custom");
  const auto provider = codex ? AgentProvider::codex : cursor ? AgentProvider::cursor
                                                   : custom   ? static_cast<AgentProvider>(6)
                                                              : AgentProvider::claude;
  std::ofstream dump{arguments[4], std::ios::binary};
  ProtocolPeer subscribed{arguments[2]};
  if (workload.ends_with("-events")) {
    notifications = &subscribed;
    subscribed.send(RequestRuntimeState{.client_identity = 901, .interactive = false});
  }
  paint("\x1b[2J\x1b[H");
  waitState(peer, codex || cursor ? AgentStatus::unknown : AgentStatus::ready, AgentSource::foreground_process);
  recordAgents(peer, dump);
  peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});

  const auto started = std::chrono::steady_clock::now();
  for (unsigned index = 0; index < iterations; ++index) {
    paint(custom ? "\x1b[2J\x1b[1;1HCustom Agent\x1b[20;1HCustom processing" : codex ? "\x1b[2J\x1b[20;1HWorking (1s)\x1b[22;1H› Ask Codex to do anything\x1b[22;3H"
                                                                           : cursor  ? "\x1b[2J\x1b[20;1H⠞ Working\x1b[22;1H→ Add a follow-up"
                                                                                     : "\x1b[2J\x1b[1;1HClaude Code\x1b[20;1Hesc to interrupt");
    waitState(peer, AgentStatus::working, AgentSource::screen);
    recordAgents(peer, dump);
    if (codex || cursor) {
      peer.exchange<RequestCompleted>(ReportAgent{.request_id = 1, .pane_id = pane, .pane_generation = generation, .provider = provider, .state = AgentReportState::working});
      if (cursor) {
        paint("\x1b[20;1H\x1b[2K\x1b[21;1Hnot in allowlist:");
        waitState(peer, AgentStatus::blocked, AgentSource::screen);
        recordAgents(peer, dump);
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = provider, .state = AgentReportState::ready});
        waitState(peer, AgentStatus::blocked, AgentSource::screen);
        recordAgents(peer, dump);
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = 3, .pane_id = pane, .pane_generation = generation, .provider = provider, .state = AgentReportState::exited});
      } else {
        paint("\x1b[20;1H\x1b[2K\x1b[22;3H");
        waitState(peer, AgentStatus::working, AgentSource::lifecycle_report);
        recordAgents(peer, dump);
        peer.exchange<RequestCompleted>(ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = provider, .state = AgentReportState::settling});
      }
    }

    paint(custom ? "\x1b[2J\x1b[1;1HCustom Agent\x1b[22;1HCustom ready" : codex ? "\x1b[20;1H\x1b[2K\x1b[22;3H"
                                                                      : cursor  ? "\x1b[2J\x1b[22;1H→ Add a follow-up"
                                                                                : "\x1b[2J\x1b[1;1HClaude Code\x1b[22;1H❯ ");
    waitState(peer, cursor ? AgentStatus::ready : AgentStatus::done, AgentSource::screen);
    recordAgents(peer, dump);
    peer.send(AcknowledgeAgent{pane, generation});
    waitState(peer, AgentStatus::ready, AgentSource::screen, !cursor);
    recordAgents(peer, dump);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{arguments[5]} << "{\"iterations\":" << iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / iterations << "}\n";
  return 0;
}

int main(int argc, char **argv) {
  try {
    if (argc == 7 && std::string_view{argv[1]} == "--child") {
      return child(argv);
    }
    if (argc != 5) {
      return 2;
    }
    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const std::string_view workload{argv[2]};
    const auto executable = (root / (workload.starts_with("screen-custom") ? "fixture-agent" : workload.starts_with("screen-codex") ? "codex"
                                                                                           : workload.starts_with("screen-cursor")  ? "cursor-agent"
                                                                                                                                    : "claude"))
                                .string();
    const auto result_path = (root / "screen-result.json").string();
    std::filesystem::copy_file(argv[0], executable);
    ProtocolPeer peer{argv[1]};
    const auto cwd = std::filesystem::canonical("/tmp").string();
    const std::array<std::string_view, 7> arguments{executable, "--child", argv[1], argv[3], argv[4], result_path, argv[2]};
    peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = cwd, .arguments = arguments}});
    const auto exited = peer.receive<PaneExited>();
    std::ifstream result{result_path};
    if (exited.kind != ExitKind::exited || exited.value != 0 || !result.good()) {
      std::cerr << result.rdbuf();
      return 1;
    }
    std::cout << result.rdbuf();
    return 0;
  } catch (const std::exception &error) {
    if (argc == 7) {
      std::ofstream{argv[5]} << error.what() << '\n';
    }
    std::fprintf(stderr, "screen-probe: %s\n", error.what());
    return 1;
  }
}
