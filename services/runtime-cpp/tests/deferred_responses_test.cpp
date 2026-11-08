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
  check(snapshot.tabs.front().label == "Current tab" && snapshot.tabs.front().pane_count == 0 && snapshot.tabs.front().foregrounds.empty());

  pane.close_requested = false;
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
