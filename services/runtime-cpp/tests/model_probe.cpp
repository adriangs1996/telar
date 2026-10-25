#include "check.hpp"
#include "protocol_peer.hpp"
#include <chrono>

using namespace telar;

static void verifyResync(ProtocolPeer &peer, std::uint64_t workspace, bool closed) {
  const auto change = peer.receive<ResyncRequired>();
  check(change.workspace.id == workspace && change.workspace_closed == closed);
}

static void verifyGeometry(ProtocolPeer &owner, ProtocolPeer &observer, const PaneOpened &pane, Launch launch) {
  const TerminalSize size{90, 30, 0, 0};
  observer.exchange<PaneOpened>(OpenPane{.request_id = 2, .target = {.kind = PaneTarget::Kind::pane, .id = pane.pane_id}, .size = size});
  bool denied = false;
  try {
    observer.exchange<PaneOpened>(CreatePane{.request_id = 3, .location = pane.location, .size = size, .launch = launch});
  } catch (const ProtocolFailure &failure) {
    denied = failure.code == FailureCode::resource_limit;
  }
  check(denied);
  owner.send(DetachPane{pane.pane_id});
  verifyResync(observer, pane.location.workspace.id, false);
  observer.exchange<PaneOpened>(OpenPane{.request_id = 4, .target = {.kind = PaneTarget::Kind::pane, .id = pane.pane_id}, .size = size});
  observer.send(DetachPane{pane.pane_id});
}

int main(int argc, char **argv) {
  if (argc != 5 || std::string_view{argv[2]} != "model") {
    return 2;
  }

  try {
    ProtocolPeer owner{argv[1]};
    ProtocolPeer observer{argv[1]};
    owner.send(RequestRuntimeState{.client_identity = 17, .interactive = true});
    observer.send(RequestRuntimeState{.client_identity = 18, .interactive = false});
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    const TerminalSize size{80, 24, 0, 0};
    const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = launch});
    observer.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 1, .workspace = opened.location.workspace});
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    std::ofstream dump{argv[4], std::ios::binary};
    const auto started = std::chrono::steady_clock::now();
    for (unsigned index = 0; index < iterations; ++index) {
      const auto renamed = owner.exchange<WorkspaceSnapshot>(RenameWorkspace{.request_id = index + 2, .workspace = opened.location.workspace, .name = index % 2 == 0 ? "Named workspace" : "Other name"});
      check(renamed.name == (index % 2 == 0 ? "Named workspace" : "Other name"));
      check(renamed.tabs.size() == 1);
      owner.record(dump, renamed);
      verifyResync(observer, opened.location.workspace.id, false);
      const auto tab = owner.exchange<TabRenamed>(RenameTab{.request_id = index + 1000, .location = opened.location, .label = "Renamed tab"});
      owner.record(dump, tab);
      verifyResync(observer, opened.location.workspace.id, false);
    }
    const auto elapsed = std::chrono::steady_clock::now() - started;
    verifyGeometry(owner, observer, opened, launch);

    const auto second = owner.exchange<PaneOpened>(CreateWorkspace{.request_id = 10000, .size = size, .name = "Second", .launch = launch});
    observer.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 10001, .workspace = second.location.workspace});
    const auto closed = owner.exchange<TabClosed>(CloseTab{.request_id = 10002, .location = second.location});
    check(closed.workspace_closed && closed.previous_workspace == opened.location.workspace.id);
    const auto resync = observer.receive<ResyncRequired>();
    check(resync.workspace_closed && resync.workspace.id == second.location.workspace.id && resync.previous_workspace == opened.location.workspace.id);
    owner.record(dump, closed);
    owner.record(dump, resync);
    std::printf("{\"ns_per_iteration\":%.2f}\n", static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count()) / iterations);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
