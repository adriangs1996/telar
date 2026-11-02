#include "client_peer.hpp"
#include "runtime/workspace_service.hpp"

using namespace telar;
using namespace telar::runtime;

static void testHeldTabCapacity() {
  HeldTabs held;
  for (std::size_t index = 0; index < HeldTabs::capacity; ++index) {
    check(held.insert(TabLocation{.workspace = {.id = 1}, .tab_id = index + 1}));
  }

  const TabLocation first{.workspace = {.id = 1}, .tab_id = 1};
  const TabLocation other_workspace{.workspace = {.id = 2}, .tab_id = 1};
  check(held.insert(first));
  check(!held.contains(other_workspace) && !held.insert(other_workspace));
  check(held.erase(first) && !held.erase(first));
  check(held.insert(other_workspace));

  std::size_t count = 0;
  while (const auto location = held.pop()) {
    check(!held.contains(*location));
    ++count;
  }
  check(count == HeldTabs::capacity);
}

static void testHeldTabLifecycle() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer holder{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  constexpr TerminalSize size{80, 24, 0, 0};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = size, .launch = launch});
  const auto opened = owner.receive<PaneOpened>();
  const auto location = opened.location;

  for (auto *peer : {&owner, &holder}) {
    workspaces.holdTab(peer->session(), HoldTab{.request_id = 2, .location = location, .held = true});
    check(peer->receive<RequestCompleted>().request_id == 2);
  }

  auto &pane = panes.require(opened.pane_id);
  pane.output_closed = true;
  pane.exit_status = 0;
  panes.release(owner.session(), pane.id);
  workspaces.collectExited();
  check(model.panes.find(opened.pane_id) == nullptr);
  check(workspaces.requireTab(location).panes.empty());
  workspaces.tabSnapshot(owner.session(), RequestTabSnapshot{3, location});
  check(owner.receive<TabSnapshot>().panes.empty());

  workspaces.holdTab(owner.session(), HoldTab{.request_id = 4, .location = location, .held = false});
  owner.receive<RequestCompleted>();
  check(model.tabHeld(location));
  holder.session().connection.closing = true;
  check(!model.tabHeld(location));
  holder.session().connection.closing = false;

  workspaces.createPane(owner.session(), CreatePane{.request_id = 5, .location = location, .size = size, .launch = launch});
  const auto reopened = owner.receive<PaneOpened>();
  check(reopened.location.tab_id == location.tab_id);
  workspaces.releaseHeldTabs(holder.session());
  check(!model.tabHeld(location) && !workspaces.requireTab(location).panes.empty());

  workspaces.holdTab(owner.session(), HoldTab{.request_id = 6, .location = location, .held = true});
  owner.receive<RequestCompleted>();
  workspaces.closeTab(owner.session(), CloseTab{.request_id = 7, .location = location});
  check(owner.receive<TabClosed>().workspace_closed);
  check(model.workspaces.find(location.workspace.id) == nullptr);
  workspaces.releaseHeldTabs(owner.session());
  check(!model.tabHeld(location));
}

static void testHeldTabRelease() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::control};
  ClientPeer holder{memory, model, ClientRole::control};
  const auto workspace_id = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, workspace_id, "/tmp", "Held tabs");
  for (std::size_t index = 0; index < HeldTabs::capacity; ++index) {
    workspace->tabs.emplace_back(memory, index + 1, "Empty");
  }
  model.workspaces.insert(workspace_id, std::move(workspace));
  const auto other_id = model.workspaces.nextId();
  auto other = makeOwned<Workspace<SystemAllocator>>(memory, memory, other_id, "/", "Other workspace");
  other->tabs.emplace_back(memory, HeldTabs::capacity + 1, "Empty");
  model.workspaces.insert(other_id, std::move(other));
  owner.session().workspace = workspace_id;
  holder.session().workspace = workspace_id;
  const TabLocation first{.workspace = {.id = workspace_id}, .tab_id = 1};

  for (std::size_t index = 0; index < HeldTabs::capacity; ++index) {
    auto location = first;
    location.tab_id += index;
    workspaces.holdTab(owner.session(), HoldTab{.request_id = index + 1, .location = location, .held = true});
    owner.receive<RequestCompleted>();
  }

  auto overflow = first;
  overflow.workspace.id = other_id;
  overflow.tab_id = HeldTabs::capacity + 1;
  bool refused = false;
  try {
    workspaces.holdTab(owner.session(), HoldTab{.request_id = 100, .location = overflow, .held = true});
  } catch (const RequestError &error) {
    refused = error.code() == FailureCode::resource_limit && std::string_view{error.what()} == "this client holds too many tabs";
  }
  check(refused);

  workspaces.holdTab(holder.session(), HoldTab{.request_id = 101, .location = first, .held = true});
  holder.receive<RequestCompleted>();
  owner.session().connection.closing = true;
  workspaces.releaseHeldTabs(owner.session());
  check(workspaces.require(first.workspace).tabs.size() == 1);
  check(model.tabHeld(first));
  for (std::size_t index = 1; index < HeldTabs::capacity; ++index) {
    check(!holder.receive<TabClosed>().workspace_closed);
  }

  workspaces.holdTab(holder.session(), HoldTab{.request_id = 102, .location = overflow, .held = true});
  holder.receive<RequestCompleted>();
  workspaces.releaseHeldTabs(holder.session());
  check(holder.receive<TabClosed>().workspace_closed);
  check(model.workspaces.find(workspace_id) == nullptr);
  check(model.workspaces.find(other_id) == nullptr);

  bool missing = false;
  try {
    workspaces.holdTab(holder.session(), HoldTab{.request_id = 103, .location = first, .held = false});
  } catch (const RequestError &error) {
    missing = error.code() == FailureCode::tab_not_found && std::string_view{error.what()} == "tab not found";
  }
  check(missing);
}

void testTabHolds() {
  testHeldTabCapacity();
  testHeldTabLifecycle();
  testHeldTabRelease();
}
