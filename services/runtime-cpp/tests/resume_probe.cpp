#include "protocol_peer.hpp"
#include "telar_config/agents/provider.hpp"
#include <algorithm>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>

using namespace telar;
using namespace telar::runtime;

static void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

static void runProvider(int count, char **arguments) {
  const auto *directory = std::getenv("RESUME_FIXTURE_OUTPUT");
  const auto *pane = std::getenv("TELAR_PANE_ID");
  require(directory != nullptr && pane != nullptr, "Missing resume fixture environment");
  const auto path = std::filesystem::path{directory} / pane;
  const auto temporary = path.string() + ".tmp";
  std::ofstream output{temporary, std::ios::binary};
  for (int index = 0; index < count; ++index) {
    output.write(arguments[index], static_cast<std::streamsize>(std::strlen(arguments[index]) + 1));
  }

  output.close();
  require(output.good(), "Cannot record resumed arguments");
  std::filesystem::rename(temporary, path);
  std::fputs("\x1b[2J\x1b[Hresume-ready\n", stdout);
  std::fflush(stdout);
  for (;;) {
    ::pause();
  }
}

static void waitText(ProtocolPeer &peer, std::uint64_t pane, std::string_view marker) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    const auto output = peer.exchange<PaneText>(ReadPane{.request_id = 10, .pane_id = pane, .rows = 24});
    if (output.text.contains(marker)) {
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Restored pane did not produce its marker"};
}

static std::size_t waitPanes(ProtocolPeer &peer, const char *path) {
  std::ifstream input{path};
  require(input.good(), "Cannot read expected restored panes");
  std::uint64_t pane = 0;
  bool provider = false;
  std::size_t providers = 0;
  while (input >> pane >> provider) {
    if (provider) {
      ++providers;
      waitText(peer, pane, "resume-ready");
    } else {
      peer.exchange<RequestCompleted>(SendPaneText{.request_id = 11, .pane_id = pane, .mode = PaneTextMode::raw, .text = "printf 'shell-'; printf 'ready\\n'\r"});
      waitText(peer, pane, "shell-ready");
    }
  }

  return providers;
}

static void snapshot(ProtocolPeer &peer, std::size_t providers, const char *path) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    auto snapshot = peer.exchange<AgentSnapshot>(QueryAgents{12});
    if (snapshot.entries.size() == providers) {
      std::vector<AgentSnapshotEntry> entries{snapshot.entries.begin(), snapshot.entries.end()};
      for (auto &entry : entries) {
        entry.pane_generation = 1;
        entry.process_id = 1;
        entry.session_id = {};
        entry.status_age_s = 0;
        entry.sequence = 1;
        entry.observed_at_ms = 0;
        entry.expires_at_ms = 0;
      }

      std::ranges::sort(entries, {}, &AgentSnapshotEntry::pane_id);
      snapshot.entries = entries;
      snapshot.revision = 1;
      std::ofstream output{path, std::ios::binary};
      peer.record(output, snapshot);
      require(output.good(), "Cannot record restored agents");
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Restored providers were not identified"};
}

int main(int argc, char **argv) {
  try {
    const auto name = std::filesystem::path{argv[0]}.filename().string();
    if (providerNamed(name == "cursor-agent" ? "cursor" : name) != AgentProvider::unknown) {
      runProvider(argc, argv);
    }
    if (argc != 4) {
      return 2;
    }

    ProtocolPeer peer{argv[1]};
    const auto providers = waitPanes(peer, argv[2]);
    snapshot(peer, providers, argv[3]);
    peer.exchange<RuntimeStopping>(RuntimeStop{});
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "resume-probe: %s\n", error.what());
    return 1;
  }
}
