#include "check.hpp"
#include "protocol_peer.hpp"
#include <chrono>
#include <filesystem>
#include <thread>

using namespace telar;

int main(int argc, char **argv) {
  if (argc != 4) {
    return 2;
  }
  try {
    const std::filesystem::path fixture{argv[2]};
    const auto main = (fixture / "repository").string();
    const auto linked = (fixture / "linked").string();
    ProtocolPeer peer{argv[1]};
    const std::array<std::string_view, 3> command{"/bin/sh", "-c", "IFS= read -r directory; cd \"$directory\" || exit 1; printf '\\033]7;file://localhost%s\\007' \"$PWD\"; exec /bin/cat"};
    const auto pane = peer.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .name = "Repository", .launch = Launch{.cwd = main, .arguments = command}});
    peer.send(RequestRuntimeState{.client_identity = 73, .interactive = false});
    const auto initial = peer.receive<WorkspaceList>();
    check(initial.worktrees.empty());
    const auto input = linked + "/nested\r";
    peer.exchange<RequestCompleted>(SendPaneText{.request_id = 2, .pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .mode = PaneTextMode::raw, .text = input});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{15};
    std::ofstream dump{argv[3], std::ios::binary};
    for (;;) {
      const auto list = peer.receive<WorkspaceList>();
      check(std::chrono::steady_clock::now() < deadline);
      if (list.worktrees.empty()) {
        continue;
      }
      if (list.worktrees.size() != 1) {
        std::string paths;
        for (const auto &entry : list.worktrees) {
          paths += std::string{entry.path} + "\n";
        }
        throw std::runtime_error{"Unexpected worktree entries: " + paths};
      }
      auto entry = list.worktrees[0];
      check(entry.source == pane.location.workspace.id && entry.origin == WorktreeOrigin::external && !entry.workspace);
      check(std::filesystem::equivalent(entry.path, linked) && entry.branch == "feature");
      if (entry.base != "main") {
        continue;
      }
      check(entry.state == WorktreeState::active && entry.diff_files == 0 && entry.commits_ahead == 0);
      entry.worktree = 1;
      entry.source = 1;
      entry.path = "/fixture/linked";
      peer.record(dump, WorkspaceList{.revision = 1, .worktrees = std::span{&entry, 1}});
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{750});
    ProtocolPeer retained{argv[1]};
    retained.send(RequestRuntimeState{.client_identity = 74, .interactive = false});
    const auto stable = retained.receive<WorkspaceList>();
    if (stable.worktrees.size() != 1) {
      std::string paths;
      for (const auto &entry : stable.worktrees) {
        paths += std::string{entry.path} + "\n";
      }
      throw std::runtime_error{"Unstable worktree entries: " + paths};
    }
    peer.exchange<RuntimeStopping>(RuntimeStop{});
    std::puts("{\"cwd_change_detected\":true,\"ancestor_root\":true,\"source_workspace\":true,\"external_origin\":true,\"main_base_discovered\":true}");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "worktree-detection-probe: %s\n", error.what());
    return 1;
  }
}
