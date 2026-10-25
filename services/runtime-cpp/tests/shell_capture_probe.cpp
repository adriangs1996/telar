#include "protocol_peer.hpp"
#include <chrono>
#include <filesystem>
#include <iostream>
#include <thread>

using namespace telar;

namespace {

constexpr std::string_view prompt = "TELAR_READY>";
constexpr std::array<std::string_view, 6> shell_commands{
    "printf 'DONE0\\n'",
    "/bin/sh -c \"printf 'DONE1\\n'; exit 3\"",
    "cd /; printf 'DONE2\\n'",
    " printf 'DONE3\\n'",
    "printf 'DONE4\\n'",
    "exit 7",
};

void waitPrompt(ProtocolPeer &peer, std::uint64_t pane, std::string_view marker) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    const auto result = peer.exchange<PaneText>(ReadPane{.request_id = 1, .pane_id = pane, .rows = 24});
    if (result.text.contains(marker)) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  } while (std::chrono::steady_clock::now() < deadline);
  throw std::runtime_error{"Interactive shell did not reach its next prompt"};
}

void recordHistory(const char *socket, std::string_view directory, std::span<const std::string_view> commands, std::ostream &output, bool change_directory) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    ProtocolPeer peer{socket};
    auto result = peer.exchange<HistoryResults>(QueryHistory{.request_id = 1, .limit = 20});
    if (result.entries.size() != commands.size() - 1) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
      continue;
    }

    std::vector<HistoryEntry> entries{result.entries.begin(), result.entries.end()};
    constexpr std::array<std::size_t, 5> sequences{5, 4, 2, 1, 0};
    for (std::size_t index = 0; index < entries.size(); ++index) {
      auto &entry = entries[index];
      const auto sequence = sequences[index];
      const auto expected_directory = change_directory && sequence >= 4 ? std::string_view{"/"} : directory;
      if (entry.command != commands[sequence] || entry.cwd != expected_directory || entry.origin != HistoryOrigin::pane || entry.status != HistoryStatus::completed) {
        throw std::runtime_error{"Unexpected shell capture at " + std::to_string(sequence) + ": " + std::string{entry.command} + ", cwd=" + std::string{entry.cwd} + ", author=" + std::to_string(static_cast<unsigned>(entry.author))};
      }
      if (sequence == 5 && entry.exit_code != 7) {
        throw std::runtime_error{"Missing shell exit status"};
      }
      entry.id = sequence + 1;
      entry.pane_id = 1;
      entry.started_at_ms = sequence + 1;
      entry.duration_ns = 0;
    }
    result.entries = entries;
    result.snapshot_id = entries.size();
    peer.record(output, result);
    return;
  } while (std::chrono::steady_clock::now() < deadline);
  throw std::runtime_error{"Interactive shell history did not settle"};
}

}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    ProtocolPeer peer{argv[1]};
    const bool change_directory = std::string_view{argv[2]} == "shell-capture-cwd";
    auto commands = shell_commands;
    if (!change_directory) {
      commands[2] = "printf 'DONE2\\n'";
    }

    const auto directory = std::filesystem::canonical("/tmp").string();
    constexpr std::string_view launch = "PS1='TELAR_READY> '; export PS1; ENV=/dev/null; export ENV; exec /bin/sh -i";
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", launch};
    const auto pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {100, 24, 8, 16}, .launch = Launch{.cwd = directory, .arguments = arguments}});
    waitPrompt(peer, pane.pane_id, prompt);
    const auto started = std::chrono::steady_clock::now();
    for (std::size_t index = 0; index < commands.size(); ++index) {
      const auto input = std::string{commands[index]} + '\r';
      if (index == 4) {
        peer.exchange<RequestCompleted>(SendPaneText{.request_id = 2, .pane_id = pane.pane_id, .mode = PaneTextMode::raw, .text = input});
      } else {
        peer.send(PaneInput{.pane_id = pane.pane_id, .bytes = {reinterpret_cast<const Byte *>(input.data()), input.size()}});
      }
      if (index + 1 < commands.size()) {
        waitPrompt(peer, pane.pane_id, "\nDONE" + std::to_string(index) + "\n" + std::string{prompt});
      }
    }
    const auto exited = peer.receive<PaneExited>();
    if (exited.kind != ExitKind::exited || exited.value != 7) {
      throw std::runtime_error{"Interactive shell did not exit with status 7"};
    }
    std::ofstream output{argv[4], std::ios::binary};
    recordHistory(argv[1], directory, commands, output, change_directory);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::cout << "{\"ns_per_iteration\":" << elapsed / commands.size() << "}\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "shell-capture-probe: " << error.what() << '\n';
    return 1;
  }
}
