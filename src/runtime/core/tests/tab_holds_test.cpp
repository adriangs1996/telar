#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
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
#include <ghostty/vt.h>
#include <new>
#include <sys/stat.h>

import std;
import telar.base.memory.allocators;

import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.core.tests.client_peer;
import telar.runtime.core.runtime;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.core.model.client_layouts;
import telar.runtime.core.model.slot_store;
import telar.runtime.host.event_loop;
import telar.runtime.core.execution_service;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testHeldTabCapacity() {
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

  void testHeldTabLifecycle() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
    WorkspaceService<decltype(poller)> workspaces{memory};
    ClientPeer owner{memory, model, clients, ClientRole::interactive};
    ClientPeer holder{memory, model, clients, ClientRole::control};
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    constexpr TerminalSize size{80, 24, 0, 0};

    workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = launch});
    const auto opened = owner.receive<PaneOpened>();
    const auto location = opened.location;

    for (auto* peer : {&owner, &holder}) {
      workspaces.holdTab(model, panes, clients, peer->session().id, HoldTab{.request_id = 2, .location = location, .held = true});
      check(peer->receive<RequestCompleted>().request_id == 2);
    }

    auto& pane = panes.require(model.panes, opened.pane_id);

    pane.output_closed = true;
    pane.exit_status = 0;
    panes.release(model, clients, {.client = owner.session().id, .pane = pane.id});
    workspaces.collectExited(model, panes, clients);
    check(model.panes.find(opened.pane_id) == nullptr);
    check(workspaces.requireTab(model.workspaces, location).panes.empty());
    workspaces.tabSnapshot(model, clients, owner.session().id, RequestTabSnapshot{3, location});
    check(owner.receive<TabSnapshot>().panes.empty());

    workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = 4, .location = location, .held = false});
    owner.receive<RequestCompleted>();
    check(tabHeld(clients, location));
    holder.session().connection.flagsMut().closing = true;
    check(!tabHeld(clients, location));
    holder.session().connection.flagsMut().closing = false;

    workspaces.createPane(model, panes, clients, owner.session().id, CreatePane{.request_id = 5, .location = location, .size = size, .launch = launch});
    const auto reopened = owner.receive<PaneOpened>();

    check(reopened.location.tab_id == location.tab_id);
    workspaces.releaseHeldTabs(model, panes, clients, holder.session().id);
    check(!tabHeld(clients, location) && !workspaces.requireTab(model.workspaces, location).panes.empty());

    workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = 6, .location = location, .held = true});
    owner.receive<RequestCompleted>();
    workspaces.closeTab(model, owner.session(), CloseTab{.request_id = 7, .location = location});
    check(owner.receive<TabClosed>().workspace_closed);
    check(model.workspaces.find(location.workspace.id) == nullptr);
    workspaces.releaseHeldTabs(model, panes, clients, owner.session().id);
    check(!tabHeld(clients, location));
  }

  void testHeldTabRelease() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
    WorkspaceService<decltype(poller)> workspaces{memory};
    ClientPeer owner{memory, model, clients, ClientRole::control};
    ClientPeer holder{memory, model, clients, ClientRole::control};
    const auto workspace_id = model.workspaces.nextId();
    auto workspace = ds::makeBox<Workspace>(memory, memory, WorkspaceSpec{.id = workspace_id, .path = "/tmp", .name = "Held tabs"});

    for (std::size_t index = 0; index < HeldTabs::capacity; ++index) {
      workspace.getMut().tabs.emplace(memory, index + 1, "Empty");
    }

    model.workspaces.insert(workspace_id, std::move(workspace));
    const auto other_id = model.workspaces.nextId();
    auto other = ds::makeBox<Workspace>(memory, memory, WorkspaceSpec{.id = other_id, .path = "/", .name = "Other workspace"});

    other.getMut().tabs.emplace(memory, HeldTabs::capacity + 1, "Empty");
    model.workspaces.insert(other_id, std::move(other));
    owner.session().workspace = workspace_id;
    holder.session().workspace = workspace_id;
    const TabLocation first{.workspace = {.id = workspace_id}, .tab_id = 1};

    for (std::size_t index = 0; index < HeldTabs::capacity; ++index) {
      auto location = first;

      location.tab_id += index;
      workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = index + 1, .location = location, .held = true});
      owner.receive<RequestCompleted>();
    }

    auto overflow = first;

    overflow.workspace.id = other_id;
    overflow.tab_id = HeldTabs::capacity + 1;
    bool refused = false;

    try {
      workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = 100, .location = overflow, .held = true});
    } catch (const RequestError& error) {
      refused = error.code() == FailureCode::resource_limit && std::string_view{error.what()} == "this client holds too many tabs";
    }

    check(refused);

    workspaces.holdTab(model, panes, clients, holder.session().id, HoldTab{.request_id = 101, .location = first, .held = true});
    holder.receive<RequestCompleted>();
    owner.session().connection.flagsMut().closing = true;
    workspaces.releaseHeldTabs(model, panes, clients, owner.session().id);
    check(workspaces.require(model.workspaces, first.workspace).tabs.size() == 1);
    check(tabHeld(clients, first));
    for (std::size_t index = 1; index < HeldTabs::capacity; ++index) {
      check(!holder.receive<TabClosed>().workspace_closed);
    }

    workspaces.holdTab(model, panes, clients, holder.session().id, HoldTab{.request_id = 102, .location = overflow, .held = true});
    holder.receive<RequestCompleted>();
    workspaces.releaseHeldTabs(model, panes, clients, holder.session().id);
    check(holder.receive<TabClosed>().workspace_closed);
    check(model.workspaces.find(workspace_id) == nullptr);
    check(model.workspaces.find(other_id) == nullptr);

    bool missing = false;

    try {
      workspaces.holdTab(model, panes, clients, holder.session().id, HoldTab{.request_id = 103, .location = first, .held = false});
    } catch (const RequestError& error) {
      missing = error.code() == FailureCode::tab_not_found && std::string_view{error.what()} == "tab not found";
    }

    check(missing);
  }

  const telar::testing::Case case_held_tab_capacity{"tab_holds.held_tab_capacity", testHeldTabCapacity};
  const telar::testing::Case case_held_tab_lifecycle{"tab_holds.held_tab_lifecycle", testHeldTabLifecycle};
  const telar::testing::Case case_held_tab_release{"tab_holds.held_tab_release", testHeldTabRelease};

}
