#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <sqlite3.h>
#include <termios.h>
#include <cstdio>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.client.protocol;
import telar.runtime.tests.agent_oracle;
import telar.runtime.history.store;

using namespace telar;
using namespace telar::runtime;

static std::string_view active_phase = "startup";
static unsigned active_iteration = 0;

static std::string_view promptFor(std::string_view workload) {
  if (workload == "description-paste") {
    return "\x1b[200~Fix\ncafé\x1b[201~\r";
  }
  if (workload == "description-cancel") {
    return "discard me\x03"
           "Fix café\r";
  }
  if (workload == "description-edit") {
    return "incorrect\x15"
           "Fix café\r";
  }
  if (workload == "description-invalid") {
    return "invalid\r";
  }
  if (workload == "description-failed") {
    return "failed\r";
  }
  if (workload == "description-overflow") {
    return "overflow\r";
  }
  if (workload == "description-timeout") {
    return "timeout\r";
  }
  if (workload == "description-override") {
    return "override\r";
  }
  if (workload != "description-success") {
    throw std::runtime_error{"Unknown description fixture"};
  }

  return "Fix café\r";
}

static AgentSnapshotEntry waitTitle(ProtocolPeer &notices, AgentTitleState state, std::string_view title = {}) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (std::chrono::steady_clock::now() < deadline) {
    const auto snapshot = notices.receive<AgentSnapshot>();
    if (snapshot.entries.size() == 1 && snapshot.entries[0].title_state == state && (title.empty() || snapshot.entries[0].session_title == title)) {
      return snapshot.entries[0];
    }
  }

  throw std::runtime_error{"Description did not reach the expected title state"};
}

static void recordStoredTitle(const std::filesystem::path &path, const AgentSnapshotEntry &agent, std::ostream &dump) {
  Database database{path.c_str(), DatabaseAccess::read_only};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (std::chrono::steady_clock::now() < deadline) {
    Statement title{database, "SELECT title, title_source, title_state FROM session WHERE id=?1"};
    title.bind(1, std::span{agent.session_id});
    if (title.next() && !title.isNull(2) && title.integer(2) == static_cast<int>(agent.title_state)) {
      dump << title.text(0) << ':' << title.integer(1) << ':' << title.integer(2) << '\n';
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  throw std::runtime_error{"Description was not persisted in history"};
}

static int child(char **arguments) {
  const auto pane = std::stoull(std::getenv("TELAR_PANE_ID"));
  const auto generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
  const std::string_view workload{arguments[6]};
  termios settings;
  if (::tcgetattr(STDIN_FILENO, &settings) != 0) {
    throw std::runtime_error{"Cannot read fixture terminal settings"};
  }

  ::cfmakeraw(&settings);
  if (::tcsetattr(STDIN_FILENO, TCSANOW, &settings) != 0) {
    throw std::runtime_error{"Cannot configure fixture terminal"};
  }

  active_phase = "child registration";
  ProtocolPeer peer{arguments[2]};
  peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
  peer.exchange<RequestCompleted>(ReportAgent{.request_id = 2, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::claude, .state = AgentReportState::ready});
  ProtocolPeer notices{arguments[2]};
  notices.send(RequestRuntimeState{.client_identity = 601, .interactive = false});
  active_phase = "initial placeholder notification";
  waitTitle(notices, AgentTitleState::placeholder);
  std::ofstream dump{arguments[4], std::ios::binary | std::ios::app};
  recordAgents(peer, dump);

  const auto prompt = promptFor(workload);
  active_phase = "submit prompt";
  const auto started = std::chrono::steady_clock::now();
  peer.exchange<RequestCompleted>(SendPaneText{.request_id = 3, .pane_id = pane, .pane_generation = generation, .mode = PaneTextMode::raw, .text = prompt});
  std::array<char, 128> received;
  std::size_t length = 0;
  while (length != prompt.size()) {
    const auto count = ::read(STDIN_FILENO, received.data() + length, prompt.size() - length);
    if (count <= 0) {
      throw std::runtime_error{"Description prompt did not reach the pane"};
    }
    length += static_cast<std::size_t>(count);
  }

  if (std::string_view{received.data(), length} != prompt) {
    throw std::runtime_error{"Description capture modified terminal input"};
  }
  peer.exchange<RequestCompleted>(ReportAgent{.request_id = 4, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::claude, .state = AgentReportState::working});
  constexpr std::string_view activity = "Working\r\n";
  if (::write(STDOUT_FILENO, activity.data(), activity.size()) != static_cast<ssize_t>(activity.size())) {
    throw std::runtime_error{"Cannot paint agent activity"};
  }

  active_phase = "description result notification";
  if (workload == "description-override") {
    waitTitle(notices, AgentTitleState::pending);
    recordAgents(peer, dump);
    peer.exchange<RequestCompleted>(ReportAgentTitle{.request_id = 5, .pane_id = pane, .pane_generation = generation, .provider = AgentProvider::claude, .title = "Agent chosen title"});
    waitTitle(notices, AgentTitleState::ready, "Agent chosen title");
    std::this_thread::sleep_for(std::chrono::milliseconds{350});
  } else {
    const bool failed = workload == "description-invalid" || workload == "description-failed" || workload == "description-overflow" || workload == "description-timeout";
    const auto agent = waitTitle(notices, failed ? AgentTitleState::failed : AgentTitleState::ready, failed ? std::string_view{} : "Fix café");
    recordStoredTitle(std::filesystem::path{arguments[4]}.parent_path() / "description.sqlite3", agent, dump);
  }

  recordAgents(peer, dump);
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  std::ofstream{arguments[5]} << elapsed << '\n';
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
    const auto executable = (root / "claude").string();
    const auto result_path = (root / "description-result.txt").string();
    std::filesystem::copy_file(argv[0], executable);
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    ProtocolPeer peer{argv[1]};
    const auto directory = std::filesystem::canonical("/tmp").string();
    std::int64_t elapsed = 0;
    for (unsigned index = 0; index < iterations; ++index) {
      active_iteration = index + 1;
      active_phase = "open workspace";
      const std::array<std::string_view, 7> arguments{executable, "--child", argv[1], argv[3], argv[4], result_path, argv[2]};
      peer.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .name = "Descriptions", .launch = Launch{.cwd = directory, .arguments = arguments}});
      active_phase = "wait for child exit";
      const auto exited = peer.receive<PaneExited>();
      std::ifstream result{result_path};
      if (exited.kind != ExitKind::exited || exited.value != 0 || !result.good()) {
        std::cerr << result.rdbuf();
        return 1;
      }

      std::int64_t duration;
      result >> duration;
      elapsed += duration;
      active_phase = "wait for agent retirement";
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
      while (!peer.exchange<AgentSnapshot>(QueryAgents{3}).entries.empty()) {
        if (std::chrono::steady_clock::now() >= deadline) {
          throw std::runtime_error{"Exited description fixture remained in the agent registry"};
        }
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
      }
    }

    std::cout << "{\"iterations\":" << iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / iterations << "}\n";
    return 0;
  } catch (const std::exception &error) {
    if (argc == 7) {
      std::ofstream{argv[5]} << active_phase << ": " << error.what() << '\n';
    }
    std::fprintf(stderr, "description-probe: iteration %u, %.*s: %s\n", active_iteration, static_cast<int>(active_phase.size()), active_phase.data(), error.what());
    return 1;
  }
}
