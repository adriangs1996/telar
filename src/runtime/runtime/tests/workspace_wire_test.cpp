#include <climits>
#include <cstdlib>

import std;
import telar.testing;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.runtime.runtime.tests.wire_session;
import telar.wire.clients;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr ds::Array<std::string_view, 1> cat{"/bin/cat"};

  // The code a request that answers `Reply` failed with, or nothing when it was answered.
  template <typename Reply, typename Request>
  ds::Option<FailureCode> failure(ProtocolPeer& peer, const Request& request) {
    try {
      peer.exchange<Reply>(request);
      return ds::none;
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }
  }

  std::vector<std::uint64_t> tabOrder(ProtocolPeer& peer, WorkspaceLocation workspace, std::uint64_t request) {
    const auto snapshot = peer.exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.request_id = request, .workspace = workspace});
    std::vector<std::uint64_t> tabs;

    for (const auto& tab : snapshot.tabs) {
      tabs.push_back(tab.tab_id);
    }

    return tabs;
  }

  void testWorkspaceCapacity() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    ds::Option<FailureCode> refused;
    std::uint64_t request = 1;

    // Workspaces until the runtime holds no more.
    for (; request <= 70 && !refused; ++request) {
      refused = failure<PaneOpened>(control, CreateWorkspace{.request_id = request, .size = size, .name = "Filled", .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    }

    check(refused == FailureCode::resource_limit, "a workspace past the runtime's capacity was not refused as a limit");

    // The client that reached the limit is still served.
    check(control.exchange<ClientList>(QueryClients{.request_id = request}).request_id == request);
  }

  void testCreateDirectoriesForNewWorkspace() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto nested = host.directory() + "/new/project/root";
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "pwd; echo created-in; exec cat"};

    // The GUI's "create directory" opens a workspace where nothing exists yet.
    const auto opened = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "New", .create_cwd = true, .launch = Launch{.cwd = nested, .arguments = arguments}});

    check(std::filesystem::is_directory(nested));
    check(screenShowing(control, opened.pane_id, "created-in").contains("new/project/root"));

    // Asking again for a directory that exists is no error.
    control.exchange<PaneOpened>(CreateWorkspace{.request_id = 2, .size = size, .name = "Again", .create_cwd = true, .launch = Launch{.cwd = nested, .arguments = cat}});

    // A relative path names no place the user chose.
    check(failure<PaneOpened>(control, CreateWorkspace{.request_id = 3, .size = size, .name = "Relative", .create_cwd = true, .launch = Launch{.cwd = "relative/dir", .arguments = cat}}) == FailureCode::invalid_request);
    check(!std::filesystem::exists("relative/dir"), "a relative path was created under the runtime's directory");
  }

  void testMoveTabRelative() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto workspace = opened.location.workspace;
    const auto a = opened.location.tab_id;
    const auto b = control.exchange<TabCreated>(CreateTab{.request_id = 2, .workspace = workspace, .label = "B", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}).location.tab_id;
    const auto c = control.exchange<TabCreated>(CreateTab{.request_id = 3, .workspace = workspace, .label = "C", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}).location.tab_id;

    // A before C, from in front of it.
    const auto before = control.exchange<TabMoved>(MoveTab{.request_id = 4, .location = {workspace, a}, .direction = TabMoveDirection::previous, .relative_to = c});

    check(before.position == 1 && tabOrder(control, workspace, 5) == std::vector<std::uint64_t>{b, a, c});

    // C after B, from behind it: [B, A, C] becomes [B, C, A].
    const auto after = control.exchange<TabMoved>(MoveTab{.request_id = 6, .location = {workspace, c}, .direction = TabMoveDirection::next, .relative_to = b});

    check(after.position == 1 && tabOrder(control, workspace, 7) == std::vector<std::uint64_t>{b, c, a});
    check(failure<TabMoved>(control, MoveTab{.request_id = 8, .location = {workspace, a}, .direction = TabMoveDirection::next, .relative_to = 9999}) == FailureCode::tab_not_found);
  }

  void testTabLimitAndRollback() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto workspace = opened.location.workspace;
    const ds::Array<std::string_view, 1> missing{"/nonexistent/telar-missing-program"};

    // A tab whose program cannot start leaves no empty tab behind, opened either way.
    check(failure<TabCreated>(control, CreateTab{.request_id = 2, .workspace = workspace, .label = "Broken", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = missing}}).hasValue());
    check(failure<PaneOpened>(control, LaunchTab{.request_id = 3, .workspace = workspace.id, .label = "Broken", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = missing}}).hasValue());
    check(tabOrder(control, workspace, 4).size() == 1, "a failed launch left an empty tab");

    // Background tabs up to the workspace's 64.
    for (std::uint64_t request = 5; request < 5 + 63; ++request) {
      control.exchange<PaneOpened>(LaunchTab{.request_id = request, .workspace = workspace.id, .label = "Filled", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    }

    check(tabOrder(control, workspace, 100).size() == 64);
    check(failure<PaneOpened>(control, LaunchTab{.request_id = 101, .workspace = workspace.id, .label = "Past", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}) == FailureCode::resource_limit);
    check(failure<TabCreated>(control, CreateTab{.request_id = 102, .workspace = workspace, .label = "Past", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}}) == FailureCode::resource_limit);
    check(tabOrder(control, workspace, 103).size() == 64);
  }

  void testBackgroundTabRefusesBorrowedDirectory() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Project", .launch = Launch{.cwd = host.directory(), .arguments = cat}});
    const auto workspace = opened.location.workspace.id;

    // A background tab has no pane to take a directory from.
    check(failure<PaneOpened>(control, LaunchTab{.request_id = 3, .workspace = workspace, .label = "Borrowed", .size = size, .launch = Launch{.cwd = "/tmp", .cwd_source = opened.pane_id, .arguments = cat}}) == FailureCode::invalid_request);
  }

  // A window sends `update`, then its layout is what a window of the same identity restores.
  ClientLayoutSnapshot layoutAfter(const RuntimeHost& host, std::uint64_t identity, std::span<const UpdateClientLayout> updates) {
    {
      ProtocolPeer window{host.socket()};

      window.send(RequestRuntimeState{.client_identity = identity, .interactive = true});
      for (const auto& update : updates) {
        window.send(update);
      }

      window.exchange<ClientList>(QueryClients{.request_id = 1});
    }

    ProtocolPeer restored{host.socket()};

    restored.send(RequestRuntimeState{.client_identity = identity, .interactive = true});
    restored.deadline(std::chrono::seconds{5});
    return restored.receive<ClientLayoutSnapshot>();
  }

  ClientTabLayout tabLayout(const TabCreated& tab, bool workspace_active, std::span<const ClientLayoutNode> nodes) {
    return ClientTabLayout{.location = tab.location, .focused_pane = tab.root_pane_id, .workspace_active = workspace_active, .nodes = nodes};
  }

  bool shows(const ClientLayoutSnapshot& layout, TabLocation location, bool workspace_active) {
    return std::ranges::any_of(layout.tabs, [&](const ClientTabLayout& tab) {
      return tab.location.workspace.id == location.workspace.id && tab.location.tab_id == location.tab_id && tab.workspace_active == workspace_active;
    });
  }

  void testLayoutMergeKeepsOtherWorkspaces() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto first = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto a1 = TabCreated{.location = first.location, .root_pane_id = first.pane_id};
    const auto a2 = control.exchange<TabCreated>(CreateTab{.request_id = 2, .workspace = first.location.workspace, .label = "A2", .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto second = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 3, .size = size, .name = "B", .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto b1 = TabCreated{.location = second.location, .root_pane_id = second.pane_id};
    const ds::Array<ClientLayoutNode, 1> a1_nodes{ClientLayoutPane{a1.root_pane_id}};
    const ds::Array<ClientLayoutNode, 1> a2_nodes{ClientLayoutPane{a2.root_pane_id}};
    const ds::Array<ClientLayoutNode, 1> b1_nodes{ClientLayoutPane{b1.root_pane_id}};
    const ds::Array<ClientTabLayout, 2> workspace_a{tabLayout(a1, true, a1_nodes), tabLayout(a2, false, a2_nodes)};
    const ds::Array<ClientTabLayout, 1> workspace_b{tabLayout(b1, true, b1_nodes)};
    const ds::Array<ClientTabLayout, 1> back_to_a{tabLayout(a2, true, a2_nodes)};

    // The window shows A, then switches to B: A's tabs stay, A1 still A's active tab.
    const ds::Array<UpdateClientLayout, 2> switched{UpdateClientLayout{true, 30, false, a1.location, workspace_a}, UpdateClientLayout{true, 30, false, b1.location, workspace_b}};
    const auto both = layoutAfter(host, 91, switched);

    check(both.restored && both.tabs.size() == 3, "switching workspaces forgot the other workspace's tabs");
    check(shows(both, a1.location, true) && shows(both, a2.location, false) && shows(both, b1.location, true));

    // Back in A on A2: A1 is no longer A's active tab, and B keeps its own.
    const ds::Array<UpdateClientLayout, 1> returned{UpdateClientLayout{true, 30, false, a2.location, back_to_a}};
    const auto again = layoutAfter(host, 91, returned);

    check(again.tabs.size() == 3 && shows(again, a1.location, false) && shows(again, a2.location, true) && shows(again, b1.location, true));
  }

  void testLayoutsEvictLeastRecentlyUsed() {
    RuntimeHost host;
    ProtocolPeer control{host.socket()};
    const auto opened = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const ds::Array<ClientLayoutNode, 1> nodes{ClientLayoutPane{opened.pane_id}};
    const ds::Array<ClientTabLayout, 1> tabs{ClientTabLayout{.location = opened.location, .focused_pane = opened.pane_id, .workspace_active = true, .nodes = nodes}};
    const ds::Array<UpdateClientLayout, 1> update{UpdateClientLayout{true, 30, false, opened.location, tabs}};

    // As many windows as the runtime remembers, the first of them reopened since.
    for (std::uint64_t identity = 1; identity <= 16; ++identity) {
      layoutAfter(host, identity, update);
    }

    check(layoutAfter(host, 1, {}).restored);

    // A new window takes a place, and the window just reopened keeps its own.
    check(layoutAfter(host, 17, update).restored);
    check(layoutAfter(host, 1, {}).restored, "the most recently used layout was evicted");
  }

  const telar::testing::Case case_workspace_capacity{"workspace_wire.workspace_capacity", testWorkspaceCapacity};
  const telar::testing::Case case_create_directories_for_new_workspace{"workspace_wire.create_directories_for_new_workspace", testCreateDirectoriesForNewWorkspace};
  const telar::testing::Case case_move_tab_relative{"workspace_wire.move_tab_relative", testMoveTabRelative};
  const telar::testing::Case case_tab_limit_and_rollback{"workspace_wire.tab_limit_and_rollback", testTabLimitAndRollback};
  const telar::testing::Case case_background_tab_refuses_borrowed_directory{"workspace_wire.background_tab_refuses_borrowed_directory", testBackgroundTabRefusesBorrowedDirectory};
  const telar::testing::Case case_layout_merge_keeps_other_workspaces{"workspace_wire.layout_merge_keeps_other_workspaces", testLayoutMergeKeepsOtherWorkspaces};
  const telar::testing::Case case_layouts_evict_least_recently_used{"workspace_wire.layouts_evict_least_recently_used", testLayoutsEvictLeastRecentlyUsed};

}
