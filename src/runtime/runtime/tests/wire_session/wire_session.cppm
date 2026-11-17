module;
#include <cerrno>
#include <poll.h>
#include <sys/socket.h>

export module telar.runtime.runtime.tests.wire_session;

import std;
import telar.runtime.runtime.tests.protocol_peer;
import telar.testing;
import telar.wire.content;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;

using telar::testing::check;

// What the tests that drive a runtime over its socket ask of it, as a client sees it.
export {
  // True once the runtime closed the peer's connection, reading and discarding what it sent first.
  bool closedByRuntime(int descriptor, std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    std::array<char, 4096> bytes;

    for (;;) {
      const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
      if (remaining.count() <= 0) {
        return false;
      }

      pollfd ready{.fd = descriptor, .events = POLLIN, .revents = 0};
      if (::poll(&ready, 1, static_cast<int>(remaining.count())) <= 0) {
        continue;
      }

      const auto count = ::recv(descriptor, bytes.data(), bytes.size(), 0);
      if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN)) {
        return true;
      }
    }
  }

  // The code a request failed with, or nothing when the runtime completed it.
  template <typename Request>
  std::optional<telar::FailureCode> refusal(ProtocolPeer& peer, const Request& request) {
    try {
      peer.exchange<telar::RequestCompleted>(request);
      return std::nullopt;
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
}
