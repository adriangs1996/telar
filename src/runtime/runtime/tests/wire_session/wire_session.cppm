module;
#include <cerrno>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>

export module telar.runtime.runtime.tests.wire_session;

import std;
import telar.platform.process;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.testing;
import telar.wire.agents;
import telar.wire.content;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

using telar::testing::check;

namespace {

  // A pane's program that keeps every byte its terminal hands it, in RECORD, and the terminal's
  // size at each read, in RECORD.size: argv is `--record-input RECORD [bracketed]`.
  int recordInput(int argc, char** argv) {
    if (argc < 3) {
      return 2;
    }

    const std::string record = argv[2];
    termios mode{};

    ::tcgetattr(STDIN_FILENO, &mode);
    ::cfmakeraw(&mode);
    ::tcsetattr(STDIN_FILENO, TCSANOW, &mode);
    if (argc > 3 && std::string_view{argv[3]} == "bracketed") {
      constexpr std::string_view bracketed = "\x1b[?2004h";

      static_cast<void>(::write(STDOUT_FILENO, bracketed.data(), bracketed.size()));
    }

    constexpr std::string_view ready = "recording\r\n";

    static_cast<void>(::write(STDOUT_FILENO, ready.data(), ready.size()));
    telar::ds::Array<char, 4096> input;

    for (;;) {
      const auto count = ::read(STDIN_FILENO, input.dataMut(), input.size());
      if (count <= 0) {
        return 0;
      }

      winsize window{};

      ::ioctl(STDIN_FILENO, TIOCGWINSZ, &window);
      std::ofstream{record, std::ios::app | std::ios::binary}.write(input.data(), count);
      std::ofstream{record + ".size"} << window.ws_col << 'x' << window.ws_row;
    }
  }

  const telar::testing::Mode record_input{"--record-input", recordInput};

}

// What the tests that drive a runtime over its socket ask of it, as a client sees it.
export {
  // True once the runtime closed the peer's connection, reading and discarding what it sent first.
  bool closedByRuntime(int descriptor, std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    telar::ds::Array<char, 4096> bytes;

    for (;;) {
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
      if (remaining.count() <= 0) {
        return false;
      }

      pollfd ready{.fd = descriptor, .events = POLLIN, .revents = 0};
      if (::poll(&ready, 1, static_cast<int>(remaining.count())) <= 0) {
        continue;
      }

      const auto count = ::recv(descriptor, bytes.dataMut(), bytes.size(), 0);
      if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN)) {
        return true;
      }
    }
  }

  // The code a request failed with, or nothing when the runtime completed it.
  template <typename Request>
  telar::ds::Option<telar::FailureCode> refusal(ProtocolPeer& peer, const Request& request) {
    try {
      peer.exchange<telar::RequestCompleted>(request);
      return telar::ds::none;
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }
  }

  // The pane's screen once it shows `marker`.
  std::string screenShowing(ProtocolPeer& peer, std::uint64_t pane, std::string_view marker) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    for (std::uint64_t request = 1000;; ++request) {
      const auto text = peer.exchange<telar::PaneText>(telar::ReadPane{.request_id = request, .pane_id = pane, .rows = 200});
      if (text.text.contains(marker)) {
        return std::string{text.text};
      }

      check(std::chrono::steady_clock::now() < deadline, "the pane never showed the expected text");
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  // Waits for the pane's PaneExited, which the client that opened the pane receives.
  void waitExited(ProtocolPeer& peer, std::uint64_t pane) {
    peer.deadline(std::chrono::seconds{30});
    while (peer.receive<telar::PaneExited>().pane_id != pane) {
    }
  }

  std::string readFile(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, {}};
  }

  // The process a pane runs under an agent's executable name: the test binary, copied as `name`
  // into the host's directory, to run in one of its fixture modes.
  std::string agentExecutable(const RuntimeHost& host, std::string_view name) {
    const telar::runtime::ExecutablePath self;
    const auto path = host.directory() + "/" + std::string{name};

    if (!std::filesystem::exists(path)) {
      std::filesystem::copy_file(self.c_str(), path);
    }

    return path;
  }

  // Waits until the runtime names the pane's agent, by the executable a fixture runs as.
  void waitProvider(ProtocolPeer& peer, std::uint64_t pane, telar::AgentProvider provider) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    for (std::uint64_t request = 100;; ++request) {
      const auto snapshot = peer.exchange<telar::AgentSnapshot>(telar::QueryAgents{request});
      if (std::ranges::any_of(snapshot.entries, [&](const auto& entry) {
            return entry.pane_id == pane && entry.provider == provider;
          })) {
        return;
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        throw std::runtime_error{"the runtime never named the pane's agent"};
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{5});
    }
  }

  // A pane running the recorder, opened by `owner`, which is attached to it.
  struct Recorder {
    Recorder(const RuntimeHost& host, ProtocolPeer& owner, bool bracketed = false)
        : record(host.directory() + "/input") {
      const telar::runtime::ExecutablePath self;
      const telar::ds::Array<std::string_view, 4> arguments{self.view(), "--record-input", record, bracketed ? "bracketed" : "plain"};

      opened = owner.exchange<telar::PaneOpened>(telar::OpenPane{.request_id = 1, .size = {80, 24, 8, 16}, .launch = telar::Launch{.cwd = "/tmp", .arguments = arguments}});
      screenShowing(owner, opened.pane_id, "recording");
    }

    // What the program read once it read `marker`.
    std::string received(std::string_view marker) const {
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

      for (auto text = readFile(record); !text.contains(marker); text = readFile(record)) {
        check(std::chrono::steady_clock::now() < deadline, "the program never read the expected input");
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
      }

      return readFile(record);
    }

    std::string record;
    telar::PaneOpened opened;
  };
}
