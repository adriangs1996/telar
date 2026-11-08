#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "client_peer.hpp"
#include "../diagnostics/line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <array>
#include <span>
#include <sys/types.h>
#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <optional>
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
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
#if (defined(__linux__))
#endif
#include <new>
#include "telar_config/terminal/control/policy.hpp"
#include <sys/stat.h>



import telar.runtime.runtime.runtime;

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
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer holder{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  constexpr TerminalSize size{80, 24, 0, 0};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = launch});
  const auto opened = owner.receive<PaneOpened>();
  const auto location = opened.location;

  for (auto *peer : {&owner, &holder}) {
    workspaces.holdTab(model, panes, clients, peer->session().id, HoldTab{.request_id = 2, .location = location, .held = true});
    check(peer->receive<RequestCompleted>().request_id == 2);
  }

  auto &pane = panes.require(model.panes, opened.pane_id);
  pane.output_closed = true;
  pane.exit_status = 0;
  panes.release(model, clients, owner.session().id, pane.id);
  workspaces.collectExited(model, panes, clients);
  check(model.panes.find(opened.pane_id) == nullptr);
  check(workspaces.requireTab(model.workspaces, location).panes.empty());
  workspaces.tabSnapshot(model, clients, owner.session().id, RequestTabSnapshot{3, location});
  check(owner.receive<TabSnapshot>().panes.empty());

  workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = 4, .location = location, .held = false});
  owner.receive<RequestCompleted>();
  check(tabHeld(clients, location));
  holder.session().connection.closing = true;
  check(!tabHeld(clients, location));
  holder.session().connection.closing = false;

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

static void testHeldTabRelease() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/tab-holds.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::control};
  ClientPeer holder{memory, model, clients, ClientRole::control};
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
    workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = index + 1, .location = location, .held = true});
    owner.receive<RequestCompleted>();
  }

  auto overflow = first;
  overflow.workspace.id = other_id;
  overflow.tab_id = HeldTabs::capacity + 1;
  bool refused = false;
  try {
    workspaces.holdTab(model, panes, clients, owner.session().id, HoldTab{.request_id = 100, .location = overflow, .held = true});
  } catch (const RequestError &error) {
    refused = error.code() == FailureCode::resource_limit && std::string_view{error.what()} == "this client holds too many tabs";
  }
  check(refused);

  workspaces.holdTab(model, panes, clients, holder.session().id, HoldTab{.request_id = 101, .location = first, .held = true});
  holder.receive<RequestCompleted>();
  owner.session().connection.closing = true;
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
