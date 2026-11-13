#include <sys/stat.h>
#include <cstdio>

import std;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static void awaitState(ProtocolPeer &peer, std::string_view branch, bool dirty, std::ostream &dump) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{20};
  for (;;) {
    const auto list = peer.receive<WorkspaceList>();
    check(std::chrono::steady_clock::now() < deadline);
    check(list.entries.size() == 1);
    const auto &entry = list.entries[0];
    if (entry.branch != branch || entry.dirty != dirty) {
      continue;
    }

    WorkspaceListEntry normalized{.workspace = 1, .name = "Repository", .path = "/repository", .tab_count = 1, .branch = entry.branch, .dirty = entry.dirty};
    peer.record(dump, WorkspaceList{.revision = 1, .entries = std::span{&normalized, 1}});
    return;
  }
}

int main(int argc, char **argv) {
  if (argc != 4) {
    return 2;
  }
  try {
    const std::filesystem::path root{argv[2]};
    const auto repository = root / "repository";
    const auto directory = repository.string();
    ProtocolPeer peer{argv[1]};
    const std::array<std::string_view, 1> command{"/bin/cat"};
    peer.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .name = "Repository", .launch = Launch{.cwd = directory, .arguments = command}});
    peer.send(RequestRuntimeState{.client_identity = 71, .interactive = false});
    std::ofstream dump{argv[3], std::ios::binary};
    awaitState(peer, "main", false, dump);
    std::ofstream{repository / "file.txt"} << "changed\n";
    awaitState(peer, "main", true, dump);

    std::ofstream{root / "mode"} << "failure";
    std::ofstream{repository / ".git/HEAD"} << "ref: refs/heads/observed-after-failure\n";
    awaitState(peer, "observed-after-failure", true, dump);
    std::ofstream{repository / "file.txt"} << "initial\n";
    std::ofstream{repository / ".git/HEAD"} << "ref: refs/heads/main\n";
    std::ofstream{root / "mode"} << "normal";
    awaitState(peer, "main", false, dump);

    std::string commit;
    std::ifstream{root / "commit"} >> commit;
    std::ofstream{repository / ".git/HEAD"} << commit << '\n';
    awaitState(peer, commit.substr(0, 8), false, dump);
    std::filesystem::rename(repository / ".git", root / "metadata");
    std::ofstream{repository / ".git"} << "gitdir: ../metadata\n";
    std::ofstream{root / "metadata/HEAD"} << "ref: refs/heads/main\n";
    awaitState(peer, "main", false, dump);
    std::filesystem::remove(repository / ".git");
    check(::mkfifo((repository / ".git").c_str(), 0600) == 0);
    awaitState(peer, "", false, dump);
    peer.exchange<RuntimeStopping>(RuntimeStop{});
    std::puts("{\"clean\":true,\"dirty\":true,\"failure_retains_dirty\":true,\"recovery\":true,\"detached\":true,\"relative_gitdir\":true,\"fifo_refused\":true}");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "workspace-git-probe: %s\n", error.what());
    return 1;
  }
}
