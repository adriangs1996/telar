#include "check.hpp"
#include "protocol_peer.hpp"
#include <array>
#include <chrono>

using namespace telar;

struct ExpectedSession {
  std::uint64_t workspace;
  std::uint64_t first_tab;
  std::uint64_t second_tab;
  std::array<std::uint64_t, 3> panes;
  std::array<std::uint64_t, 3> generations;
};

static constexpr std::uint64_t client_identity = 481;
static constexpr std::string_view workspace_name = "Persistent workspace";
static constexpr std::string_view tab_name = "Persistent tab";

static void saveExpected(const char *path, const ExpectedSession &expected) {
  std::ofstream file{path};
  file << expected.workspace << ' ' << expected.first_tab << ' ' << expected.second_tab;
  for (const auto identity : expected.panes) {
    file << ' ' << identity;
  }
  for (const auto generation : expected.generations) {
    file << ' ' << generation;
  }
  file << '\n';
  check(file.good());
}

static ExpectedSession loadExpected(const char *path) {
  ExpectedSession expected{};
  std::ifstream file{path};
  file >> expected.workspace >> expected.first_tab >> expected.second_tab;
  for (auto &identity : expected.panes) {
    file >> identity;
  }
  for (auto &generation : expected.generations) {
    file >> generation;
  }
  check(file.good());
  return expected;
}

static void seed(ProtocolPeer &peer, const char *path) {
  peer.send(RequestRuntimeState{.client_identity = client_identity, .interactive = false});
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  const TerminalSize size{80, 24, 0, 0};
  const auto first = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = launch});
  peer.exchange<WorkspaceSnapshot>(RenameWorkspace{.request_id = 2, .workspace = first.location.workspace, .name = workspace_name});
  const auto second = peer.exchange<PaneOpened>(CreatePane{.request_id = 3, .location = first.location, .size = size, .launch = launch});
  const auto tab = peer.exchange<TabCreated>(CreateTab{.request_id = 4, .workspace = first.location.workspace, .label = tab_name, .size = size, .launch = launch});
  const std::array<ClientLayoutNode, 1> nodes{ClientLayoutPane{tab.root_pane_id}};
  const std::array<ClientTabLayout, 1> layouts{ClientTabLayout{tab.location, tab.root_pane_id, false, true, nodes}};
  peer.send(UpdateClientLayout{true, 29, false, tab.location, layouts});
  saveExpected(path, ExpectedSession{first.location.workspace.id, first.location.tab_id, tab.location.tab_id, {first.pane_id, second.pane_id, tab.root_pane_id}, {first.pane_generation, second.pane_generation, tab.pane_generation}});
}

static void verify(ProtocolPeer &peer, const char *path, bool retained_layout = true) {
  const auto expected = loadExpected(path);
  peer.send(RequestRuntimeState{.client_identity = client_identity, .interactive = false});
  const auto layout = peer.receive<ClientLayoutSnapshot>();
  check(layout.restored == retained_layout);
  if (retained_layout) {
    check(layout.sidebar_width == 29 && layout.tabs.size() == 1);
    check(layout.active_tab && layout.active_tab->tab_id == expected.second_tab);
    check(layout.tabs.front().focused_pane == expected.panes[2]);
  }
  const auto list = peer.receive<WorkspaceList>();
  check(list.entries.size() == 1 && list.entries.front().workspace == expected.workspace);
  check(list.entries.front().name == workspace_name);

  const WorkspaceLocation location{.id = expected.workspace};
  const auto workspace = peer.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = 1, .workspace = location});
  check(workspace.tabs.size() == 2);
  check(workspace.tabs[0].tab_id == expected.first_tab && workspace.tabs[0].pane_count == 2);
  check(workspace.tabs[1].tab_id == expected.second_tab && workspace.tabs[1].label == tab_name);
  const auto first = peer.exchange<TabSnapshot>(RequestTabSnapshot{.request_id = 2, .location = {location, expected.first_tab}});
  check(first.panes.size() == 2);
  for (std::size_t index = 0; index < first.panes.size(); ++index) {
    check(first.panes[index].pane_id == expected.panes[index]);
    check(first.panes[index].pane_generation > expected.generations[index]);
    check(first.panes[index].lifecycle == PaneLifecycle::running);
  }

  const auto second = peer.exchange<TabSnapshot>(RequestTabSnapshot{.request_id = 3, .location = {location, expected.second_tab}});
  check(second.panes.size() == 1 && second.panes.front().pane_id == expected.panes[2]);
  check(second.panes.front().pane_generation > expected.generations[2]);

  if (!retained_layout) {
    constexpr std::string_view marker = "checkpoint-io";
    peer.exchange<RequestCompleted>(SendPaneText{.request_id = 4, .pane_id = expected.panes[2], .mode = PaneTextMode::raw, .text = "checkpoint-io\r"});
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    for (;;) {
      const auto output = peer.exchange<PaneText>(ReadPane{.request_id = 5, .pane_id = expected.panes[2], .rows = 24});
      if (output.text.contains(marker)) {
        break;
      }

      check(std::chrono::steady_clock::now() < deadline);
    }
  }
}

static void inspectIdentityBoundaries(ProtocolPeer &peer, const char *path) {
  std::ofstream output{path};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  for (std::uint64_t request = 1; request <= 3; ++request) {
    peer.send(CreateWorkspace{.request_id = request, .size = {80, 24, 8, 16}, .name = "Identity boundary", .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    const auto reply = peer.receiveAny<PaneOpened, RequestFailed>();
    if (const auto *opened = std::get_if<PaneOpened>(&reply)) {
      output << "opened " << opened->location.workspace.id << ' ' << opened->location.tab_id << ' ' << opened->pane_id << ' ' << opened->pane_generation << '\n';
    } else {
      const auto &failure = std::get<RequestFailed>(reply);
      output << "failed " << static_cast<unsigned>(failure.code) << ' ' << failure.message << '\n';
    }

    output.flush();
  }

  peer.exchange<ClientList>(QueryClients{.request_id = 4});
  output << "responsive\n";
  check(output.good());
}

int main(int argc, char **argv) {
  if (argc != 4) {
    std::fputs("Usage: checkpoint-probe SOCKET seed|verify EXPECTED\n", stderr);
    return 2;
  }

  try {
    ProtocolPeer peer{argv[1]};
    if (std::string_view{argv[2]} == "seed") {
      seed(peer, argv[3]);
    } else if (std::string_view{argv[2]} == "verify") {
      verify(peer, argv[3]);
    } else if (std::string_view{argv[2]} == "verify-basic") {
      verify(peer, argv[3], false);
    } else if (std::string_view{argv[2]} == "identity-boundaries") {
      inspectIdentityBoundaries(peer, argv[3]);
    } else if (std::string_view{argv[2]} == "empty") {
      peer.send(RequestRuntimeState{.client_identity = client_identity, .interactive = false});
      check(peer.receive<WorkspaceList>().entries.empty());
    } else {
      return 2;
    }

    peer.exchange<RuntimeStopping>(RuntimeStop{});
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
