#include "client_peer.hpp"
#include "runtime/launch_directory.hpp"
#include "runtime/workspace_service.hpp"

using namespace telar;
using namespace telar::runtime;

static constexpr TerminalSize size{80, 24, 0, 0};
static constexpr std::array<std::string_view, 1> arguments{"/bin/cat"};

template <typename Operation>
static void expectFailure(Operation operation, FailureCode code, std::string_view message) {
  bool rejected = false;
  try {
    operation();
  } catch (const RequestError &failure) {
    rejected = failure.code() == code && failure.what() == message;
  }
  check(rejected);
}

static void testLaunchScopes(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer outsider{memory, model, ClientRole::interactive};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  pane.cwd.assign("/observed/directory");
  const Launch launch{.cwd = "/explicit", .cwd_source = pane.id, .arguments = arguments};

  for (const LaunchDirectoryScope scope : {LaunchDirectoryScope{}, LaunchDirectoryScope{pane.location.workspace}, LaunchDirectoryScope{pane.location}}) {
    const auto resolved = resolveLaunchDirectory(model, owner.session(), launch, scope);
    check(resolved.cwd == pane.cwd && resolved.cwd_source == 0 && resolved.arguments.data() == arguments.data());
  }
  check(resolveLaunchDirectory(model, outsider.session(), Launch{.cwd = "/explicit"}).cwd == "/explicit");

  constexpr std::string_view unavailable = "cwd source pane is unavailable";
  expectFailure([&] { resolveLaunchDirectory(model, outsider.session(), launch); }, FailureCode::invalid_request, unavailable);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, WorkspaceLocation{.id = pane.location.workspace.id + 1}); }, FailureCode::invalid_request, unavailable);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, TabLocation{pane.location.workspace, pane.location.tab_id + 1}); }, FailureCode::invalid_request, unavailable);

  pane.requestClose();
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch); }, FailureCode::invalid_request, unavailable);
  pane.requestClose();
  check(pane.close_requested);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch); }, FailureCode::invalid_request, unavailable);
  pane.close_requested = false;
  pane.exit_status = 0;
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch); }, FailureCode::invalid_request, unavailable);
  pane.exit_status.reset();
  panes.detach(owner.session(), pane.id);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch); }, FailureCode::invalid_request, unavailable);

  owner.session().attachments.push_back(makeOwned<Attachment<SystemAllocator>>(memory, memory, owner.session().graphics_credit, pane.id, pane.media));
  panes.remove(pane.id);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch); }, FailureCode::invalid_request, unavailable);
}

static void testEmptyDefaultTab(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer spectator{memory, model, ClientRole::interactive};
  const auto identity = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, identity, "/", "Existing");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Default");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Running");
  auto &stored = *workspace;
  model.workspaces.insert(identity, std::move(workspace));
  const TabLocation empty{WorkspaceLocation{.id = identity}, stored.tabs.front().id};
  const Launch launch{.cwd = "/", .arguments = arguments};
  Command command{memory, launch};
  auto &existing = panes.launch(command, TabLocation{empty.workspace, stored.tabs.back().id}, size);
  stored.tabs.back().panes.push_back(existing.id);

  expectFailure([&] { workspaces.open(owner.session(), OpenPane{.request_id = 1, .target = {.kind = PaneTarget::Kind::workspace, .id = identity}, .size = size}); }, FailureCode::pane_not_found, "workspace has no running pane");
  expectFailure([&] { workspaces.createPane(owner.session(), CreatePane{.request_id = 2, .location = empty, .size = size, .launch = launch}); }, FailureCode::pane_not_found, "tab not found");

  stored.geometry_client = spectator.session().id;
  expectFailure([&] { workspaces.open(owner.session(), OpenPane{.request_id = 3, .size = size, .launch = launch}); }, FailureCode::resource_limit, "workspace geometry is leased by another client");
  releaseAllGeometry(model, spectator.session().id);
  workspaces.open(owner.session(), OpenPane{.request_id = 4, .size = size, .launch = launch});
  const auto created = owner.receive<PaneOpened>();
  check(created.created && created.location.workspace.id == identity && created.location.tab_id == empty.tab_id);
  check(stored.tabs.front().panes.size() == 1 && stored.tabs.back().panes.size() == 1);
  check(stored.geometry_client == owner.session().id);

  workspaces.open(owner.session(), OpenPane{.request_id = 5, .target = {.kind = PaneTarget::Kind::workspace, .id = identity}, .size = size});
  const auto reused = owner.receive<PaneOpened>();
  check(!reused.created && reused.pane_id == created.pane_id);
}

static void testFailedLaunchLease(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  const auto identity = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, identity, "/", "Existing");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Default");
  auto &stored = *workspace;
  model.workspaces.insert(identity, std::move(workspace));
  const CreateTab request{.request_id = 1, .workspace = {.id = identity}, .label = "Invalid", .size = size, .launch = {.cwd = "/", .cwd_source = 999, .arguments = arguments}};
  expectFailure([&] { workspaces.createTab(owner.session(), request); }, FailureCode::invalid_request, "cwd source pane is unavailable");
  check(stored.tabs.size() == 1 && stored.geometry_client == owner.session().id);
  check(!owner.session().workspace);
  releaseAllGeometry(model, owner.session().id);
  check(!stored.geometry_client);
}

static void testPaneReuseAndBackgroundColors(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  owner.session().colors.foreground = std::array<Byte, 3>{17, 34, 51};
  const Launch launch{.cwd = "/", .arguments = arguments};
  const OpenPane request{.request_id = 1, .size = size, .launch = launch};
  workspaces.open(owner.session(), request);
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  pane.terminal.refresh();
  const auto revision = pane.terminal.screen.revision;
  const auto *attachment = owner.session().attachment(pane.id);

  workspaces.open(owner.session(), request);
  const auto reused = owner.receive<PaneOpened>();
  pane.terminal.refresh();
  check(!reused.created && reused.pane_id == pane.id);
  check(owner.session().attachment(pane.id) == attachment && pane.terminal.screen.revision == revision);

  const auto &background = workspaces.launchBackground(LaunchTab{.request_id = 2, .workspace = opened.location.workspace.id, .label = "Background", .size = size, .launch = launch});
  GhosttyColorRgb foreground;
  checkGhostty(ghostty_terminal_get(background.terminal.handle(), GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &foreground));
  check(foreground.r == 17 && foreground.g == 34 && foreground.b == 51);
}

static void testExhaustedTabIdentities(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  const Launch launch{.cwd = "/", .arguments = arguments};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = size, .launch = launch});
  const auto opened = owner.receive<PaneOpened>();
  model.next_tab_id = 0;

  expectFailure([&] { workspaces.createWorkspace(owner.session(), CreateWorkspace{.request_id = 2, .size = size, .launch = launch}); }, FailureCode::resource_limit, "could not create workspace");
  expectFailure([&] { workspaces.createTab(owner.session(), CreateTab{.request_id = 3, .workspace = opened.location.workspace, .size = size, .launch = launch}); }, FailureCode::spawn_failed, "could not start the command");
  expectFailure([&] { workspaces.launchBackground(LaunchTab{.request_id = 4, .workspace = opened.location.workspace.id, .size = size, .launch = launch}); }, FailureCode::spawn_failed, "could not start the command");
  check(model.workspaces.size() == 1 && model.panes.size() == 1);
  check(model.workspaces.find(opened.location.workspace.id)->tabs.size() == 1);
}

void testLaunchDirectory() {
  SystemAllocator memory;
  testLaunchScopes(memory);
  testEmptyDefaultTab(memory);
  testFailedLaunchLease(memory);
  testPaneReuseAndBackgroundColors(memory);
  testExhaustedTabIdentities(memory);
}
