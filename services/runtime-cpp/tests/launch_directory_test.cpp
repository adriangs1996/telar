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
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer outsider{memory, model, clients, ClientRole::interactive};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  pane.cwd.assign("/observed/directory");
  const Launch launch{.cwd = "/explicit", .cwd_source = pane.id, .arguments = arguments};
  LaunchDirectory directory;

  for (const LaunchDirectoryScope scope : {LaunchDirectoryScope{}, LaunchDirectoryScope{pane.location.workspace}, LaunchDirectoryScope{pane.location}}) {
    const auto resolved = resolveLaunchDirectory(model, owner.session(), launch, directory, scope);
    check(resolved.cwd == pane.cwd && resolved.cwd_source == 0 && resolved.arguments.data() == arguments.data());
  }
  check(resolveLaunchDirectory(model, outsider.session(), Launch{.cwd = "/explicit"}, directory).cwd == "/explicit");

  constexpr std::string_view unavailable = "cwd source pane is unavailable";
  expectFailure([&] { resolveLaunchDirectory(model, outsider.session(), launch, directory); }, FailureCode::invalid_request, unavailable);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory, WorkspaceLocation{.id = pane.location.workspace.id + 1}); }, FailureCode::invalid_request, unavailable);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory, TabLocation{pane.location.workspace, pane.location.tab_id + 1}); }, FailureCode::invalid_request, unavailable);

  pane.requestClose();
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory); }, FailureCode::invalid_request, unavailable);
  pane.requestClose();
  check(pane.close_requested);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory); }, FailureCode::invalid_request, unavailable);
  pane.close_requested = false;
  pane.exit_status = 0;
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory); }, FailureCode::invalid_request, unavailable);
  pane.exit_status.reset();
  panes.detach(model, clients, owner.session().id, pane.id);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory); }, FailureCode::invalid_request, unavailable);

  owner.session().attachments.push_back(makeOwned<Attachment<SystemAllocator>>(memory, memory, owner.session().graphics_credit, pane.id, pane.media));
  panes.remove(model, clients, pane.id);
  expectFailure([&] { resolveLaunchDirectory(model, owner.session(), launch, directory); }, FailureCode::invalid_request, unavailable);
}

static void testEmptyDefaultTab(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer spectator{memory, model, clients, ClientRole::interactive};
  const auto identity = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, identity, "/", "Existing");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Default");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Running");
  auto &stored = *workspace;
  model.workspaces.insert(identity, std::move(workspace));
  const TabLocation empty{WorkspaceLocation{.id = identity}, stored.tabs.front().id};
  const Launch launch{.cwd = "/", .arguments = arguments};
  Command command{memory, launch};
  auto &existing = panes.launch(model, nullptr, command, TabLocation{empty.workspace, stored.tabs.back().id}, size);
  stored.tabs.back().panes.push_back(existing.id);

  expectFailure([&] { workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .target = {.kind = PaneTarget::Kind::workspace, .id = identity}, .size = size}); }, FailureCode::pane_not_found, "workspace has no running pane");
  expectFailure([&] { workspaces.createPane(model, panes, clients, owner.session().id, CreatePane{.request_id = 2, .location = empty, .size = size, .launch = launch}); }, FailureCode::pane_not_found, "tab not found");

  stored.geometry_client = spectator.session().id;
  expectFailure([&] { workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 3, .size = size, .launch = launch}); }, FailureCode::resource_limit, "workspace geometry is leased by another client");
  releaseAllGeometry(model.workspaces, clients, spectator.session().id);
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 4, .size = size, .launch = launch});
  const auto created = owner.receive<PaneOpened>();
  check(created.created && created.location.workspace.id == identity && created.location.tab_id == empty.tab_id);
  check(stored.tabs.front().panes.size() == 1 && stored.tabs.back().panes.size() == 1);
  check(stored.geometry_client == owner.session().id);

  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 5, .target = {.kind = PaneTarget::Kind::workspace, .id = identity}, .size = size});
  const auto reused = owner.receive<PaneOpened>();
  check(!reused.created && reused.pane_id == created.pane_id);
}

static void testFailedLaunchLease(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  const auto identity = model.workspaces.nextId();
  auto workspace = makeOwned<Workspace<SystemAllocator>>(memory, memory, identity, "/", "Existing");
  workspace->tabs.emplace_back(memory, model.next_tab_id++, "Default");
  auto &stored = *workspace;
  model.workspaces.insert(identity, std::move(workspace));
  const CreateTab request{.request_id = 1, .workspace = {.id = identity}, .label = "Invalid", .size = size, .launch = {.cwd = "/", .cwd_source = 999, .arguments = arguments}};
  expectFailure([&] { workspaces.createTab(model, panes, clients, owner.session().id, request); }, FailureCode::invalid_request, "cwd source pane is unavailable");
  check(stored.tabs.size() == 1 && stored.geometry_client == owner.session().id);
  check(!owner.session().workspace);
  releaseAllGeometry(model.workspaces, clients, owner.session().id);
  check(!stored.geometry_client);
}

static void testPaneReuseAndBackgroundColors(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  owner.session().colors.foreground = std::array<Byte, 3>{17, 34, 51};
  const Launch launch{.cwd = "/", .arguments = arguments};
  const OpenPane request{.request_id = 1, .size = size, .launch = launch};
  workspaces.open(model, panes, clients, owner.session().id, request);
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  pane.terminal.refresh();
  const auto revision = pane.terminal.screen.revision;
  const auto *attachment = owner.session().attachment(pane.id);

  workspaces.open(model, panes, clients, owner.session().id, request);
  const auto reused = owner.receive<PaneOpened>();
  pane.terminal.refresh();
  check(!reused.created && reused.pane_id == pane.id);
  check(owner.session().attachment(pane.id) == attachment && pane.terminal.screen.revision == revision);

  const auto &background = *model.panes.find(workspaces.launchBackground(model, panes, decltype(workspaces)::ownerColors(model.workspaces, clients, opened.location.workspace.id), LaunchTab{.request_id = 2, .workspace = opened.location.workspace.id, .label = "Background", .size = size, .launch = launch}));
  GhosttyColorRgb foreground;
  checkGhostty(ghostty_terminal_get(background.terminal.handle(), GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &foreground));
  check(foreground.r == 17 && foreground.g == 34 && foreground.b == 51);
}

static void testExhaustedTabIdentities(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/launch-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  const Launch launch{.cwd = "/", .arguments = arguments};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = launch});
  const auto opened = owner.receive<PaneOpened>();
  model.next_tab_id = 0;

  expectFailure([&] { workspaces.createWorkspace(model, panes, clients, owner.session().id, CreateWorkspace{.request_id = 2, .size = size, .launch = launch}); }, FailureCode::resource_limit, "could not create workspace");
  expectFailure([&] { workspaces.createTab(model, panes, clients, owner.session().id, CreateTab{.request_id = 3, .workspace = opened.location.workspace, .size = size, .launch = launch}); }, FailureCode::spawn_failed, "could not start the command");
  expectFailure([&] { workspaces.launchBackground(model, panes, nullptr, LaunchTab{.request_id = 4, .workspace = opened.location.workspace.id, .size = size, .launch = launch}); }, FailureCode::spawn_failed, "could not start the command");
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
