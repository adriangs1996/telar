#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "client_peer.hpp"
#include <span>
#include <string_view>
#include <array>
#include <optional>
#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include "telar_client/serializers/telar_protocol.hpp"
#include <exception>
#include <cstddef>
#include "telar_base/program_identity.hpp"
#include <cerrno>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <sys/types.h>
#include <limits.h>
#include <atomic>
#include <chrono>
#include <poll.h>
#include <sys/wait.h>
#include <charconv>
#include "telar_base/memory/fixed_text.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include "telar_platform/trace.hpp"
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
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
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <sys/mman.h>
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include <csignal>
#include <sys/uio.h>
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



import telar.runtime.platform.launch_program;
import telar.runtime.runtime.runtime;

using namespace telar;
using namespace telar::runtime;

static void testProgramLabels() {
  const std::array<std::string_view, 1> direct{"/usr/bin/command"};
  const std::array<std::string_view, 3> script{"/bin/sh", "-c", "exec /bin/cat"};
  std::array<std::string_view, 6> wrapped{"/bin/zsh", "-l", "-i", "-c", "exec -- \"$0\" \"$@\"", "/bin/cat"};
  check(launchedProgram({}).empty());
  check(launchedProgram(direct) == direct.front());
  check(launchedProgram(script) == script.front());
  check(launchedProgram(wrapped) == wrapped.back());
  check(launchedProgram(std::span{wrapped}.first(5)) == wrapped.front());
  wrapped[4] = "echo \"$0\"";
  check(launchedProgram(wrapped) == wrapped.front());
  wrapped[0] = "/bin/fish";
  wrapped[4] = "exec $argv";
  check(launchedProgram(wrapped) == wrapped.back());
  wrapped[1] = "-li";
  check(launchedProgram(wrapped) == wrapped.front());
}

static void testDeferredClosure(bool worktree) {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/closure-fixture.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer observer{memory, model, clients, ClientRole::interactive};
  constexpr TerminalSize size{80, 24, 0, 0};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  panes.attach(model, observer.session(), pane.id, size);
  constexpr std::string_view final_output = "retained final output";
  pane.terminal.feed({reinterpret_cast<const Byte *>(final_output.data()), final_output.size()});

  if (worktree) {
    workspaces.closeWorkspace(model, clients, opened.location.workspace.id);
    const auto notification = observer.receive<TabClosed>();
    check(notification.request_id == 0 && notification.workspace_closed && notification.location.tab_id == opened.location.tab_id);
  } else {
    workspaces.closeTab(model, owner.session(), CloseTab{.request_id = 2, .location = opened.location});
    workspaces.deliverNotices(clients);
    check(observer.session().workspace_resync.has_value());
  }
  const auto response = owner.receive<TabClosed>();
  check(response.workspace_closed && response.location.tab_id == opened.location.tab_id);
  check(model.workspaces.find(opened.location.workspace.id) == nullptr);
  check(model.panes.find(opened.pane_id) == &pane && pane.close_requested);
  check(!owner.session().attachments.empty() && !observer.session().attachments.empty());
  check(owner.session().workspace == opened.location.workspace.id);

  pane.output_closed = true;
  pane.exit_status = SIGKILL;
  workspaces.collectExited(model, panes, clients);
  check(model.panes.find(opened.pane_id) != nullptr);
  panes.release(model, clients, owner.session().id, opened.pane_id);
  panes.release(model, clients, observer.session().id, opened.pane_id);
  workspaces.collectExited(model, panes, clients);
  check(model.panes.find(opened.pane_id) == nullptr);
  check(!owner.session().workspace && !observer.session().workspace);
  const auto *retained = model.exited_panes.find(opened.pane_id, opened.pane_generation);
  check(retained != nullptr && retained->exit_code == 128 + SIGKILL);
  check(retained->response(ReadPane{.rows = 24}).text == final_output);
}

void testWorktreeLifecycle() {
  testProgramLabels();
  testDeferredClosure(false);
  testDeferredClosure(true);
}
