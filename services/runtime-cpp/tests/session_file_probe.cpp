#include "agent_oracle.hpp"
#include "agents/provider.hpp"
#include "history/database.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <thread>

using namespace telar::runtime;

static constexpr std::string_view session_reference = "0192-abcd";

static AgentProvider providerFor(std::string_view workload) {
  if (workload == "session-claude") {
    return AgentProvider::claude;
  }
  if (workload == "session-codex") {
    return AgentProvider::codex;
  }
  if (workload == "session-cursor") {
    return AgentProvider::cursor;
  }

  throw std::runtime_error{"Unknown session-file fixture"};
}

static AgentSessionFileKind fileKind(AgentProvider provider) {
  return provider == AgentProvider::claude ? AgentSessionFileKind::claude_transcript : provider == AgentProvider::codex ? AgentSessionFileKind::codex_state
                                                                                                                        : AgentSessionFileKind::cursor_meta;
}

static void writeTitle(const std::string &path, AgentProvider provider, std::string_view title) {
  if (provider == AgentProvider::codex) {
    Database database{path.c_str()};
    database.execute("CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY, name TEXT)");
    Statement write{database, "INSERT INTO threads VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET name=excluded.name"};
    write.bind(1, session_reference);
    if (title.empty()) {
      write.bindNull(2);
    } else {
      write.bind(2, title);
    }
    write.finish();
    return;
  }

  std::ofstream file{path, provider == AgentProvider::claude ? std::ios::app : std::ios::trunc};
  if (provider == AgentProvider::claude) {
    file << "{\"type\":\"custom-title\",\"sessionId\":\"" << session_reference << "\",\"customTitle\":\"" << title << "\"}\n";
  } else {
    file << "{\"title\":\"" << title << "\"}";
  }
  if (!file.good()) {
    throw std::runtime_error{"Cannot write session-file fixture"};
  }
}

static void waitTitle(ProtocolPeer &peer, std::string_view title, AgentTitleSource source) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (std::chrono::steady_clock::now() < deadline) {
    const auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{1});
    if (snapshot.entries.size() == 1 && snapshot.entries[0].session_title == title && snapshot.entries[0].title_source == source) {
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{10});
  }

  throw std::runtime_error{"Session title did not become " + std::string{title}};
}

static int child(char **arguments) {
  const auto provider = providerFor(arguments[6]);
  const auto pane = std::stoull(std::getenv("TELAR_PANE_ID"));
  const auto generation = std::stoull(std::getenv("TELAR_PANE_GENERATION"));
  const auto iterations = static_cast<unsigned>(std::stoul(arguments[3]));
  const auto root = std::filesystem::path{arguments[4]}.parent_path();
  std::filesystem::create_directory(root / session_reference);
  const auto path = (root / session_reference / (provider == AgentProvider::codex ? "state.sqlite" : provider == AgentProvider::claude ? "transcript.jsonl"
                                                                                                                                       : "meta.json"))
                        .string();
  writeTitle(path, provider, "Initial file title");
  ProtocolPeer peer{arguments[2]};
  peer.exchange<RequestCompleted>(VerifyPaneDescent{1, pane, generation});
  peer.exchange<RequestCompleted>(ReportAgent{
      .request_id = 2,
      .pane_id = pane,
      .pane_generation = generation,
      .provider = provider,
      .state = AgentReportState::ready,
      .session = session_reference,
      .session_file = path,
      .session_file_kind = fileKind(provider),
  });
  if (provider == AgentProvider::claude) {
    std::this_thread::sleep_for(std::chrono::milliseconds{1200});
    waitTitle(peer, describeProvider(provider).placeholder, AgentTitleSource::telar);
  } else {
    waitTitle(peer, "Initial file title", AgentTitleSource::agent);
  }

  std::ofstream dump{arguments[4], std::ios::binary};
  recordAgents(peer, dump);
  if (provider == AgentProvider::claude) {
    writeTitle(path, provider, "Warmup title");
    waitTitle(peer, "Warmup title", AgentTitleSource::agent);
    recordAgents(peer, dump);
  }

  const auto started = std::chrono::steady_clock::now();
  for (unsigned index = 0; index < iterations; ++index) {
    const auto title = "Renamed café " + std::to_string(index);
    writeTitle(path, provider, title);
    waitTitle(peer, title, AgentTitleSource::agent);
    recordAgents(peer, dump);
  }
  writeTitle(path, provider, {});
  waitTitle(peer, describeProvider(provider).placeholder, AgentTitleSource::telar);
  recordAgents(peer, dump);
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

    const auto provider = providerFor(argv[2]);
    const auto root = std::filesystem::path{argv[4]}.parent_path();
    const auto executable = (root / (provider == AgentProvider::cursor ? "cursor-agent" : describeProvider(provider).name)).string();
    const auto result_path = (root / "session-result.json").string();
    std::filesystem::copy_file(argv[0], executable);
    ProtocolPeer peer{argv[1]};
    const std::string directory = std::filesystem::canonical("/tmp").string();
    const std::array<std::string_view, 7> arguments{executable, "--child", argv[1], argv[3], argv[4], result_path, argv[2]};
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
    if (argc == 7) {
      std::ofstream{argv[5]} << error.what() << '\n';
    }
    std::fprintf(stderr, "session-file-probe: %s\n", error.what());
    return 1;
  }
}
