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
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
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

import std;
import telar.base.diagnostics;
import telar.base.memory.allocators;

import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.platform.launch_program;
import telar.runtime.runtime.runtime;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.testing;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.event_loop;
import telar.runtime.runtime.execution_service;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testProgramLabels() {
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

  void testDeferredClosure(bool worktree) {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/closure-fixture.sock"}};
    WorkspaceService<decltype(poller)> workspaces{memory};
    ClientPeer owner{memory, model, clients, ClientRole::interactive};
    ClientPeer observer{memory, model, clients, ClientRole::interactive};
    constexpr TerminalSize size{80, 24, 0, 0};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};

    workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
    const auto opened = owner.receive<PaneOpened>();
    auto& pane = panes.require(model.panes, opened.pane_id);

    panes.attach(model, observer.session(), pane.id, size);
    constexpr std::string_view final_output = "retained final output";

    pane.terminal.feed({reinterpret_cast<const Byte*>(final_output.data()), final_output.size()}, *pane.media);

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
    const auto* retained = model.exited_panes.find(opened.pane_id, opened.pane_generation);

    check(retained != nullptr && retained->exit_code == 128 + SIGKILL);
    check(retained->response(ReadPane{.rows = 24}).text == final_output);
  }

  void testWorktreeLifecycle() {
    testDeferredClosure(false);
    testDeferredClosure(true);
  }

  const telar::testing::Case case_worktree_lifecycle{"worktree_lifecycle.worktree_lifecycle", testWorktreeLifecycle};
  const telar::testing::Case case_program_labels{"worktree_lifecycle.program_labels", testProgramLabels};

}
