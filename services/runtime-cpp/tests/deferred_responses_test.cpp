#include "client_peer.hpp"
#include "runtime/workspace_service.hpp"

using namespace telar;
using namespace telar::runtime;

void testDeferredResponses() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/deferred-responses.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer reader{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  const auto location = pane.location;
  auto &workspace = workspaces.require(location.workspace);
  const ReadPane read{.request_id = 2, .pane_id = pane.id, .pane_generation = pane.generation, .rows = 24, .source = PaneTextSource::screen};
  panes.readText(reader.session(), read);
  constexpr std::string_view changed = "Current text";
  pane.terminal.feed({reinterpret_cast<const Byte *>(changed.data()), changed.size()});
  check(reader.receive<PaneText>().text == changed);

  auto stale = read;
  stale.pane_generation = pane.generation + 1;
  panes.readText(reader.session(), stale);
  const auto missing = reader.receive<RequestFailed>();
  check(missing.code == FailureCode::pane_not_found && missing.message == "pane closed before its text was read");

  workspaces.tabSnapshot(reader.session(), RequestTabSnapshot{3, location});
  workspaces.workspaceSnapshot(reader.session(), RequestWorkspaceSnapshot{4, location.workspace});
  workspace.name = "Current workspace";
  workspace.tabs.front().label = "Current tab";
  pane.close_requested = true;
  check(reader.receive<TabSnapshot>().panes.empty());
  const auto snapshot = reader.receive<WorkspaceSnapshot>();
  check(snapshot.name == "Current workspace" && snapshot.tabs.size() == 1);
  check(snapshot.tabs.front().label == "Current tab" && snapshot.tabs.front().pane_count == 0 && snapshot.tabs.front().foregrounds.empty());

  pane.close_requested = false;
  workspaces.tabSnapshot(reader.session(), RequestTabSnapshot{5, location});
  pane.exit_status = 7 << 8;
  check(reader.receive<TabSnapshot>().panes.empty());
  panes.readText(reader.session(), read);
  check(reader.receive<PaneText>().exit_code == 7);
  pane.exit_status.reset();

  LimitService limits{model};
  limits.query(reader.session(), QueryLimits{6});
  model.limits.runtime.record(LimitReach{.name = "deferred.capacity", .value = 10}, 4);
  model.limits.refused_reports = 9;
  const auto listed = reader.receive<LimitList>();
  check(listed.entries.size() == 1 && listed.entries.front().hits == 4 && listed.refused_reports == 9);

  workspaces.workspaceSnapshot(reader.session(), RequestWorkspaceSnapshot{7, location.workspace});
  workspaces.tabSnapshot(reader.session(), RequestTabSnapshot{8, location});
  panes.readText(reader.session(), read);
  model.exited_panes.record(pane.id, pane.generation, PaneText{.text = "Exited text", .exit_code = 17});
  panes.remove(pane.id);
  model.workspaces.erase(location.workspace.id);
  const auto closed = reader.receive<RequestFailed>();
  check(closed.request_id == 7 && closed.code == FailureCode::workspace_not_found && closed.message == "workspace closed before its snapshot was sent");
  check(reader.receive<TabSnapshot>().panes.empty());
  const auto exited = reader.receive<PaneText>();
  check(exited.text == "Exited text" && exited.exit_code == 17);

  panes.readText(reader.session(), read);
  for (unsigned index = 0; index < ExitedPanes::capacity; ++index) {
    model.exited_panes.record(read.pane_id + index + 1, 1, PaneText{});
  }
  check(reader.receive<RequestFailed>().code == FailureCode::pane_not_found);
  reader.session().connection.send(RequestCompleted{.request_id = 9});
  check(reader.receive<RequestCompleted>().request_id == 9 && !reader.session().connection.closing);
}
