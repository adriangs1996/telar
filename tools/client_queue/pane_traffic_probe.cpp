// An interactive client that opens one pane, reads and acknowledges its frames for a fixed time and then
// stops the runtime, waiting for RuntimeStopping. instrument.py adds it to an instrumented copy of the
// runtime as `pane-traffic-probe`; the same source builds against the module tree and the header tree.
#include <cstdio>
#if QUEUE_TRACE_HEADERS
#include "check.hpp"
#include "protocol_peer.hpp"
#include <array>
#include <chrono>
#include <string_view>
#include <vector>
#elif QUEUE_TRACE_BASE
import std;
import telar.runtime.tests.protocol_peer;
#else
import std;
import telar.runtime.tests.protocol_peer;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
#endif

using namespace telar;
using Clock = std::chrono::steady_clock;

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fputs("Usage: pane-traffic-probe SOCKET SECONDS COMMAND [ARGUMENT...]\n", stderr);
    return 2;
  }

  try {
    ProtocolPeer peer{argv[1]};
    const auto deadline = Clock::now() + std::chrono::milliseconds{static_cast<long long>(std::atof(argv[2]) * 1000)};
    std::array<std::string_view, 16> all_arguments{};
    const auto count = std::min<std::size_t>(static_cast<std::size_t>(argc - 3), all_arguments.size());

    for (std::size_t index = 0; index < count; ++index) {
      all_arguments[index] = argv[3 + index];
    }

    peer.send(RequestRuntimeState{.client_identity = 491, .interactive = true});
    peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = std::span{all_arguments}.first(count)}});
    std::vector<Byte> scratch(512 * 1024);
    std::uint64_t frames = 0;
    std::uint64_t bytes = 0;

    while (Clock::now() < deadline) {
      const auto payload = peer.receivePayload();
      if (payload.front() != static_cast<Byte>(ServerTag::pane_frame)) {
        continue;
      }

      DecodeStorage storage{scratch};
      const auto frame = Codec::decode<PaneFrame>(payload, storage);

      ++frames;
      bytes += payload.size();
      peer.send(FrameAck{frame.pane_id, frame.frame_id});
    }

    peer.exchange<RuntimeStopping>(RuntimeStop{});
    std::printf("{\"frames\":%llu,\"bytes\":%llu}\n", static_cast<unsigned long long>(frames), static_cast<unsigned long long>(bytes));
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
