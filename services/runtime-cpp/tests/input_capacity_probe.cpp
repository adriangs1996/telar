#include "check.hpp"
#include "protocol_peer.hpp"
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <poll.h>
#include <termios.h>
#include <thread>

using namespace telar;

namespace {

void waitForText(ProtocolPeer &peer, std::uint64_t pane, std::string_view expected) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  while (std::chrono::steady_clock::now() < deadline) {
    const auto result = peer.exchange<PaneText>(ReadPane{.request_id = 1, .pane_id = pane, .rows = 24});
    if (result.text.contains(expected)) {
      return;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }

  throw std::runtime_error{"Missing terminal text: " + std::string{expected}};
}

int blockedChild(const char *release_path) {
  termios settings;
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  std::puts("input-blocked");
  std::fflush(stdout);
  while (!std::filesystem::exists(release_path)) {
    std::this_thread::sleep_for(std::chrono::milliseconds{5});
  }

  std::array<char, 65536> bytes;
  std::size_t received = 0;
  for (;;) {
    pollfd input{STDIN_FILENO, POLLIN, 0};
    const auto ready = ::poll(&input, 1, 500);
    check(ready >= 0);
    if (ready == 0) {
      break;
    }

    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    check(count > 0);
    check(std::all_of(bytes.begin(), bytes.begin() + count, [](char byte) { return byte == 'a'; }));
    received += static_cast<std::size_t>(count);
  }

  std::printf("\r\ndrained:%zu\r\n", received);
  std::fflush(stdout);
  for (;;) {
    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    if (count <= 0) {
      return 0;
    }

    check(::write(STDOUT_FILENO, bytes.data(), static_cast<std::size_t>(count)) == count);
  }
}

void saturation(const char *socket, const char *executable, const char *dump_path) {
  ProtocolPeer peer{socket};
  peer.send(RequestRuntimeState{.client_identity = 101, .interactive = true});
  const auto release_path = std::string{dump_path} + ".release";
  const std::array<std::string_view, 3> arguments{executable, "--blocked-child", release_path};
  const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 2, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  waitForText(peer, opened.pane_id, "input-blocked");
  std::ofstream dump{dump_path, std::ios::binary};
  std::size_t accepted = 0;
  std::uint64_t request_id = 10;
  for (std::size_t size = 65536; size != 0; size /= 2) {
    const std::string bytes(size, 'a');
    unsigned attempts = 0;
    for (;;) {
      check(++attempts < 32);
      peer.send(SendPaneText{.request_id = request_id++, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .mode = PaneTextMode::raw, .text = bytes});
      const auto response = peer.receiveAny<RequestCompleted, RequestFailed>();
      if (const auto *failure = std::get_if<RequestFailed>(&response)) {
        check(failure->code == FailureCode::resource_limit);
        if (size == 1) {
          auto normalized = *failure;
          normalized.request_id = 3;
          peer.record(dump, normalized);
        }
        break;
      }

      accepted += size;
    }
  }

  std::fprintf(stderr, "phase: saturated, accepted=%zu\n", accepted);
  const std::array<Byte, 3> rejected{'b', 'a', 'd'};
  peer.send(PaneInput{opened.pane_id, rejected});
  const auto clients = peer.exchange<ClientList>(QueryClients{.request_id = 4});
  check(clients.entries.size() == 1 && clients.entries.front().identity == 101);
  peer.record(dump, RequestCompleted{.request_id = 4});
  std::fprintf(stderr, "phase: interactive drop\n");
  const auto limits = peer.exchange<LimitList>(QueryLimits{.request_id = 5});
  const auto found = std::find_if(limits.entries.begin(), limits.entries.end(), [](const auto &entry) { return entry.reach.name == "panes.input_queue_capacity"; });
  check(found != limits.entries.end() && found->origin == LimitOrigin::runtime);
  check(found->reach.value == 131072 && found->reach.requested == 131075 && found->hits > 0);
  auto normalized = *found;
  normalized.hits = 1;
  normalized.last_ms = 0;
  peer.record(dump, LimitList{.request_id = 5, .entries = std::span{&normalized, 1}});

  std::fprintf(stderr, "phase: limit verified\n");
  ProtocolPeer other{socket};
  const std::array<std::string_view, 1> cat{"/bin/cat"};
  const auto healthy = other.exchange<PaneOpened>(CreateWorkspace{.request_id = 6, .size = {80, 24, 0, 0}, .name = "Independent", .launch = Launch{.cwd = "/tmp", .arguments = cat}});
  other.exchange<RequestCompleted>(SendPaneText{.request_id = 7, .pane_id = healthy.pane_id, .mode = PaneTextMode::raw_enter, .text = "independent-pane"});
  waitForText(other, healthy.pane_id, "independent-pane");
  peer.record(dump, RequestCompleted{.request_id = 7});

  std::fprintf(stderr, "phase: independent pane\n");
  std::ofstream{release_path} << "release\n";
  waitForText(peer, opened.pane_id, "drained:" + std::to_string(accepted));
  std::fprintf(stderr, "phase: drained\n");
  peer.exchange<RequestCompleted>(SendPaneText{.request_id = 8, .pane_id = opened.pane_id, .mode = PaneTextMode::raw, .text = "input-recovered"});
  waitForText(peer, opened.pane_id, "input-recovered");
  peer.record(dump, RequestCompleted{.request_id = 8});
  peer.send(ClosePane{.request_id = 9, .pane_id = opened.pane_id});
  other.send(ClosePane{.request_id = 10, .pane_id = healthy.pane_id});
}

}

int main(int argc, char **argv) {
  if (argc == 3 && std::string_view{argv[1]} == "--blocked-child") {
    return blockedChild(argv[2]);
  }
  if (argc != 5 || std::string_view{argv[2]} != "input-capacity") {
    return 2;
  }

  try {
    const auto started = std::chrono::steady_clock::now();
    saturation(argv[1], argv[0], argv[4]);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
