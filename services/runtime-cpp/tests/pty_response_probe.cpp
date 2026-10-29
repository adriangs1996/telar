#include "check.hpp"
#include "protocol_peer.hpp"
#include <algorithm>
#include <chrono>
#include <poll.h>
#include <termios.h>
#include <thread>

using namespace telar;

static std::size_t queryCursor(std::size_t queries) {
  std::string requests;
  for (std::size_t index = 0; index < queries; ++index) {
    requests += "\x1b[6n";
  }
  check(::write(STDOUT_FILENO, requests.data(), requests.size()) == static_cast<ssize_t>(requests.size()));

  std::size_t replies = 0;
  std::array<char, 4096> bytes;
  for (;;) {
    pollfd input{STDIN_FILENO, POLLIN, 0};
    const auto ready = ::poll(&input, 1, 300);
    check(ready >= 0);
    if (ready == 0) {
      return replies;
    }

    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    check(count > 0);
    replies += std::count(bytes.begin(), bytes.begin() + count, 'R');
  }
}

static int child() {
  termios settings;
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  const auto first = queryCursor(65);
  const auto recovery = queryCursor(1);
  const auto repeated = queryCursor(65);
  std::printf("pty-responses:%zu,%zu,%zu\r\n", first, recovery, repeated);
  std::fflush(stdout);
  std::array<char, 4096> input;
  for (;;) {
    const auto count = ::read(STDIN_FILENO, input.data(), input.size());
    if (count <= 0) {
      return 0;
    }
    check(::write(STDOUT_FILENO, input.data(), static_cast<std::size_t>(count)) == count);
  }
}

static void waitForText(ProtocolPeer &peer, std::uint64_t pane, std::string_view expected) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  std::string latest;
  while (std::chrono::steady_clock::now() < deadline) {
    const auto result = peer.exchange<PaneText>(ReadPane{.request_id = 1, .pane_id = pane, .rows = 24});
    latest = result.text;
    if (result.text.contains(expected)) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }
  throw std::runtime_error{"Expected " + std::string{expected} + "; received " + latest};
}

static void exercise(const char *socket, const char *executable, const char *dump_path) {
  ProtocolPeer peer{socket};
  peer.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  const std::array<std::string_view, 2> arguments{executable, "--pty-child"};
  const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 2, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  waitForText(peer, opened.pane_id, "pty-responses:65,1,65");
  peer.exchange<RequestCompleted>(SendPaneText{.request_id = 3, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .mode = PaneTextMode::raw, .text = "input-after-saturation"});
  waitForText(peer, opened.pane_id, "input-after-saturation");
  std::ofstream dump{dump_path, std::ios::binary};
  dump << "pty-responses:65,1,65\ninput-after-saturation\n";
  check(dump.good());
  peer.send(ClosePane{.request_id = 4, .pane_id = opened.pane_id});
}

int main(int argc, char **argv) {
  if (argc == 2 && std::string_view{argv[1]} == "--pty-child") {
    return child();
  }
  if (argc != 5 || std::string_view{argv[2]} != "pty-responses") {
    return 2;
  }
  try {
    const auto started = std::chrono::steady_clock::now();
    exercise(argv[1], argv[0], argv[4]);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
