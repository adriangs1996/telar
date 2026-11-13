#include <termios.h>
#include <unistd.h>

import std;
import telar.runtime.tests.protocol_peer;

using namespace telar;

struct CaptureScenario {
  bool change_directory = false;
  bool capture_output = false;
};

static void writeText(std::string_view text) {
  while (!text.empty()) {
    const auto count = ::write(STDOUT_FILENO, text.data(), text.size());
    if (count <= 0) {
      throw std::runtime_error{"Cannot paint shell fixture"};
    }
    text.remove_prefix(count);
  }
}

static void prompt(unsigned index) {
  writeText("READY " + std::to_string(index) + "\r\n\x1b]133;A\x07$ \x1b]133;B\x07");
}

static int shellFixture(unsigned iterations, CaptureScenario scenario) {
  termios settings{};
  if (::tcgetattr(STDIN_FILENO, &settings) != 0) {
    return 2;
  }
  ::cfmakeraw(&settings);
  if (::tcsetattr(STDIN_FILENO, TCSANOW, &settings) != 0) {
    return 2;
  }

  prompt(0);
  for (unsigned index = 0; index < iterations; ++index) {
    char byte = 0;
    do {
      if (::read(STDIN_FILENO, &byte, 1) != 1) {
        return 3;
      }
    } while (byte != '\r');

    const auto command = "printf 'rendered café 好 " + std::to_string(index) + "'";
    writeText(command + "\r\n\x1b]133;C\x07result\r\n");
    if (index + 1 == iterations) {
      return 7;
    }

    writeText("\x1b]133;D;" + std::to_string(index % 3) + "\x07");
    if (scenario.capture_output || (scenario.change_directory && index == 2)) {
      char boundary = 0;
      if (::read(STDIN_FILENO, &boundary, 1) != 1 || boundary != '\x03') {
        return 4;
      }
      if (scenario.change_directory && index == 2 && ::chdir("/") != 0) {
        return 4;
      }
    }

    prompt(index + 1);
  }

  return 0;
}

static void waitPrompt(ProtocolPeer &peer, std::uint64_t pane, unsigned index) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  const auto marker = "READY " + std::to_string(index);
  do {
    const auto result = peer.exchange<PaneText>(ReadPane{.request_id = 1, .pane_id = pane, .rows = 24});
    if (result.text.find(marker) != std::string_view::npos) {
      return;
    }
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Shell prompt did not appear"};
}

static void waitHistory(const char *socket, unsigned count, unsigned total, std::ostream *dump, CaptureScenario scenario) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  do {
    ProtocolPeer peer{socket};
    auto result = peer.exchange<HistoryResults>(QueryHistory{.request_id = 1, .limit = 200});
    if (result.entries.size() != count) {
      continue;
    }

    std::vector<HistoryEntry> entries{result.entries.begin(), result.entries.end()};
    for (std::size_t index = 0; index < entries.size(); ++index) {
      auto &entry = entries[index];
      const auto sequence = count - index - 1;
      const auto expected = "printf 'rendered café 好 " + std::to_string(sequence) + "'";
      const auto expected_author = sequence % 2 == 0 ? HistoryAuthor::human : HistoryAuthor::agent;
      const int expected_exit = sequence + 1 == total ? 7 : sequence % 3;
      if (entry.command != expected || entry.author != expected_author || entry.origin != HistoryOrigin::pane || entry.exit_code != expected_exit || entry.status != HistoryStatus::completed) {
        throw std::runtime_error{"Captured command differs at " + std::to_string(sequence) + ": " + std::string{entry.command} + ", author=" + std::to_string(static_cast<int>(entry.author)) + ", status=" + std::to_string(static_cast<int>(entry.status)) + ", exit=" + std::to_string(entry.exit_code.value_or(-999))};
      }

      const auto expected_directory = scenario.change_directory && sequence >= 3 ? std::string{"/"} : std::filesystem::canonical("/tmp").string();
      if (entry.cwd != expected_directory) {
        throw std::runtime_error{"Captured directory differs at " + std::to_string(sequence) + ": " + std::string{entry.cwd}};
      }

      if (scenario.capture_output && dump != nullptr) {
        ProtocolPeer output_peer{socket};
        auto output = output_peer.exchange<HistoryOutput>(ReadHistoryOutput{.request_id = 2, .id = entry.id});
        auto expected_output = expected + "\r\n\x1b]133;C\x07result\r\n";
        if (sequence + 1 != total) {
          expected_output += "\x1b]133;D;" + std::to_string(sequence % 3) + "\x07";
        }

        const std::string_view captured{reinterpret_cast<const char *>(output.content.data()), output.content.size()};
        if (output.truncated || output.observed_bytes != expected_output.size() || captured != expected_output) {
          throw std::runtime_error{"Captured output differs at " + std::to_string(sequence) + ": expected " + std::to_string(expected_output.size()) + " bytes, received " + std::to_string(output.content.size())};
        }

        output.id = sequence + 1;
        output_peer.record(*dump, output);
      }

      entry.id = sequence + 1;
      entry.pane_id = 1;
      entry.started_at_ms = sequence + 1;
      entry.duration_ns = 0;
    }

    result.snapshot_id = count;
    result.entries = entries;
    if (dump != nullptr) {
      peer.record(*dump, result);
    }
    return;
  } while (std::chrono::steady_clock::now() < deadline);

  throw std::runtime_error{"Automatic history did not persist all commands"};
}

int main(int argc, char **argv) {
  try {
    if (argc == 4 && std::string_view{argv[1]} == "--shell") {
      const std::string_view scenario = argv[3];
      return shellFixture(std::stoul(argv[2]), {.change_directory = scenario == "capture-cwd", .capture_output = scenario == "capture-output"});
    }
    if (argc != 5) {
      return 2;
    }

    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    const CaptureScenario scenario{.change_directory = std::string_view{argv[2]} == "capture-cwd", .capture_output = std::string_view{argv[2]} == "capture-output"};
    if (iterations == 0 || iterations > 200) {
      throw std::runtime_error{"Capture probe requires 1 to 200 iterations"};
    }

    ProtocolPeer peer{argv[1]};
    const auto directory = std::filesystem::canonical("/tmp").string();
    const std::array<std::string_view, 4> arguments{argv[0], "--shell", argv[3], argv[2]};
    const auto pane = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {20, 24, 8, 16}, .launch = Launch{.cwd = directory, .arguments = arguments}});
    waitPrompt(peer, pane.pane_id, 0);
    const auto started = std::chrono::steady_clock::now();
    for (unsigned index = 0; index < iterations; ++index) {
      const auto text = "typed " + std::to_string(index) + "\r";
      if (index % 2 == 0) {
        peer.send(PaneInput{.pane_id = pane.pane_id, .bytes = {reinterpret_cast<const Byte *>(text.data()), text.size()}});
      } else {
        peer.exchange<RequestCompleted>(SendPaneText{.request_id = 2, .pane_id = pane.pane_id, .mode = PaneTextMode::raw, .text = text});
      }

      if (index + 1 != iterations) {
        waitHistory(argv[1], index + 1, iterations, nullptr, scenario);
        if (scenario.capture_output || (scenario.change_directory && index == 2)) {
          constexpr std::array<Byte, 1> cancel{3};
          peer.send(PaneInput{pane.pane_id, cancel});
        }

        waitPrompt(peer, pane.pane_id, index + 1);
      }
    }

    const auto submitted = std::chrono::steady_clock::now();
    const auto exited = peer.receive<PaneExited>();
    const auto exit_received = std::chrono::steady_clock::now();
    if (exited.kind != ExitKind::exited || exited.value != 7) {
      throw std::runtime_error{"Shell fixture did not exit correctly"};
    }

    std::ofstream dump{argv[4], std::ios::binary};
    waitHistory(argv[1], iterations, iterations, &dump, scenario);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    const auto submission_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(submitted - started).count();
    const auto exit_wait_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(exit_received - submitted).count();
    std::cout << "{\"iterations\":" << iterations << ",\"elapsed_ns\":" << elapsed << ",\"ns_per_iteration\":" << elapsed / iterations << ",\"submission_ns\":" << submission_ns << ",\"exit_wait_ns\":" << exit_wait_ns << ",\"persistence_wait_ns\":" << elapsed - submission_ns - exit_wait_ns << "}\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "capture-probe: " << error.what() << '\n';
    return 1;
  }
}
