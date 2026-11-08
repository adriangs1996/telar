#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cstdint>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <new>
#include <sys/stat.h>
#include <ghostty/vt.h>

import std;
import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.client_peer;
import telar.runtime.runtime.runtime;

using namespace telar;
using namespace telar::runtime;

void testDeferredResponses() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/deferred-responses.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer reader{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  const auto location = pane.location;
  auto &workspace = workspaces.require(model.workspaces, location.workspace);
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

  workspaces.tabSnapshot(model, clients, reader.session().id, RequestTabSnapshot{3, location});
  workspaces.workspaceSnapshot(model, reader.session(), RequestWorkspaceSnapshot{4, location.workspace});
  workspace.name = "Current workspace";
  workspace.tabs.front().label = "Current tab";
  pane.close_requested = true;
  check(reader.receive<TabSnapshot>().panes.empty());
  const auto snapshot = reader.receive<WorkspaceSnapshot>();
  check(snapshot.name == "Current workspace" && snapshot.tabs.size() == 1);
  check(snapshot.tabs.front().label == "Current tab" && snapshot.tabs.front().pane_count == 0 && snapshot.tabs.front().panes.empty());

  pane.close_requested = false;
  pane.cwd.assign("/tmp/described");
  workspaces.workspaceSnapshot(model, reader.session(), RequestWorkspaceSnapshot{10, location.workspace});
  const auto described = reader.receive<WorkspaceSnapshot>();
  check(described.tabs.front().panes.size() == 1 && described.tabs.front().panes.front().pane_id == pane.id && described.tabs.front().panes.front().cwd == "/tmp/described");
  pane.cwd.assign(std::string_view{"/tmp/\0hostile", 13});
  workspaces.workspaceSnapshot(model, reader.session(), RequestWorkspaceSnapshot{11, location.workspace});
  const auto hostile = reader.receive<WorkspaceSnapshot>();
  check(hostile.tabs.front().panes.size() == 1 && hostile.tabs.front().panes.front().cwd.empty());

  workspaces.tabSnapshot(model, clients, reader.session().id, RequestTabSnapshot{5, location});
  pane.exit_status = 7 << 8;
  check(reader.receive<TabSnapshot>().panes.empty());
  panes.readText(reader.session(), read);
  check(reader.receive<PaneText>().exit_code == 7);
  pane.exit_status.reset();
  limits.query(reader.session(), QueryLimits{6});
  model.limits.runtime.record(LimitReach{.name = "deferred.capacity", .value = 10}, 4);
  model.limits.refused_reports = 9;
  const auto listed = reader.receive<LimitList>();
  check(listed.entries.size() == 1 && listed.entries.front().hits == 4 && listed.refused_reports == 9);

  workspaces.workspaceSnapshot(model, reader.session(), RequestWorkspaceSnapshot{7, location.workspace});
  workspaces.tabSnapshot(model, clients, reader.session().id, RequestTabSnapshot{8, location});
  panes.readText(reader.session(), read);
  model.exited_panes.record(pane.id, pane.generation, PaneText{.text = "Exited text", .exit_code = 17});
  panes.remove(model, clients, pane.id);
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
