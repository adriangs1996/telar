#include "check.hpp"
#include "protocol_peer.hpp"
#include <chrono>
#include <memory>
#include <thread>

using namespace telar;

static constexpr TerminalSize size{80, 24, 0, 0};
static constexpr std::array<std::string_view, 1> arguments{"/bin/cat"};

static PaneOpened openTab(ProtocolPeer &peer) {
  return peer.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Held", .launch = {.cwd = "/tmp", .arguments = arguments}});
}

static void setHold(ProtocolPeer &peer, TabLocation location, bool held, std::ostream &dump) {
  peer.record(dump, peer.exchange<RequestCompleted>(HoldTab{.request_id = 2, .location = location, .held = held}));
}

static void expectEmpty(ProtocolPeer &peer, TabLocation location, std::ostream &dump) {
  auto snapshot = peer.exchange<TabSnapshot>(RequestTabSnapshot{3, location});
  check(snapshot.panes.empty());
  snapshot.location = {.workspace = {.id = 1}, .tab_id = 1};
  peer.record(dump, snapshot);
}

static void closePane(ProtocolPeer &peer, std::uint64_t pane) {
  peer.send(ClosePane{.request_id = 9, .pane_id = pane});
  check(peer.receive<PaneExited>().pane_id == pane);
}

static void expectRemoved(ProtocolPeer &peer, TabLocation location, std::ostream &dump) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    peer.send(RequestTabSnapshot{4, location});
    const auto reply = peer.receiveAny<TabSnapshot, RequestFailed>();
    if (const auto *failure = std::get_if<RequestFailed>(&reply)) {
      check(failure->code == FailureCode::tab_not_found && failure->message == "tab not found");
      peer.record(dump, *failure);
      return;
    }

    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static void checkRelease(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  ProtocolPeer holder{socket};
  const auto opened = openTab(owner);
  setHold(owner, opened.location, true, dump);
  setHold(holder, opened.location, true, dump);
  setHold(holder, opened.location, true, dump);
  closePane(owner, opened.pane_id);
  expectEmpty(owner, opened.location, dump);
  setHold(owner, opened.location, false, dump);
  expectEmpty(owner, opened.location, dump);

  const auto reopened = owner.exchange<PaneOpened>(CreatePane{.request_id = 5, .location = opened.location, .size = size, .launch = {.cwd = "/tmp", .arguments = arguments}});
  check(reopened.created && reopened.location.tab_id == opened.location.tab_id);
  setHold(holder, opened.location, false, dump);
  check(owner.exchange<TabSnapshot>(RequestTabSnapshot{6, opened.location}).panes.size() == 1);
  setHold(holder, opened.location, true, dump);
  closePane(owner, reopened.pane_id);
  expectEmpty(owner, opened.location, dump);
  setHold(holder, opened.location, false, dump);
  expectRemoved(owner, opened.location, dump);
  const auto missing = holder.exchange<RequestFailed>(HoldTab{.request_id = 7, .location = opened.location, .held = true});
  check(missing.code == FailureCode::tab_not_found && missing.message == "tab not found");
  holder.record(dump, missing);
}

static void checkDisconnect(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  auto first = std::make_unique<ProtocolPeer>(socket);
  auto second = std::make_unique<ProtocolPeer>(socket);
  const auto opened = openTab(owner);
  setHold(*first, opened.location, true, dump);
  setHold(*second, opened.location, true, dump);
  closePane(owner, opened.pane_id);
  first.reset();
  expectEmpty(owner, opened.location, dump);
  second.reset();
  expectRemoved(owner, opened.location, dump);
}

static void checkExplicitClose(const char *socket, std::ostream &dump) {
  ProtocolPeer owner{socket};
  const auto opened = openTab(owner);
  setHold(owner, opened.location, true, dump);
  closePane(owner, opened.pane_id);
  expectEmpty(owner, opened.location, dump);
  const auto closed = owner.exchange<TabClosed>(CloseTab{.request_id = 8, .location = opened.location});
  check(closed.workspace_closed && closed.location.tab_id == opened.location.tab_id);
  expectRemoved(owner, opened.location, dump);
}

static std::int64_t checkRoundtrip(const char *socket, unsigned iterations, std::ostream &dump) {
  ProtocolPeer owner{socket};
  const auto opened = openTab(owner);
  const auto started = std::chrono::steady_clock::now();
  for (unsigned index = 0; index < iterations; ++index) {
    setHold(owner, opened.location, true, dump);
    setHold(owner, opened.location, false, dump);
  }

  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count() / iterations;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }

  try {
    std::ofstream dump{argv[4], std::ios::binary};
    const std::string_view workload{argv[2]};
    std::int64_t elapsed = 0;
    if (workload == "tab-holds") {
      const auto started = std::chrono::steady_clock::now();
      checkRelease(argv[1], dump);
      checkDisconnect(argv[1], dump);
      checkExplicitClose(argv[1], dump);
      elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    } else if (workload == "tab-hold-roundtrip") {
      const auto iterations = std::stoul(argv[3]);
      check(iterations > 0);
      elapsed = checkRoundtrip(argv[1], iterations, dump);
    } else {
      return 2;
    }

    std::printf("{\"ns_per_iteration\":%lld}\n", static_cast<long long>(elapsed));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
