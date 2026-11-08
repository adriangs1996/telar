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
#include <pthread.h>
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
import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

struct GatedLineageInspector {
  mutable std::atomic<unsigned> calls{0};
  mutable std::atomic<bool> released{false};

  ProcessLineage lineage(const ProcessIdentity &, pid_t root) const noexcept {
    calls.fetch_add(1, std::memory_order_release);
    while (!released.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    return {.processes = {root}, .count = 1, .descends = true};
  }
};

template <typename Condition>
static void waitUntil(Condition &&condition) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (!condition()) {
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::yield();
  }
}

void testDescent() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  model.panes.insert(1, makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
  auto &pane = *model.panes.find(1);
  GatedLineageInspector inspector;
  DescentService<SystemAllocator, decltype(inspector)> service{inspector};
  ClientPeer first{memory, model, clients, ClientRole::control};
  ClientPeer second{memory, model, clients, ClientRole::control};
  first.session().peer_identity = ProcessIdentity{41};
  second.session().peer_identity = ProcessIdentity{42};
  service.verify(model.panes, first.session(), VerifyPaneDescent{1, 1, 1});
  service.schedule(clients);
  waitUntil([&] { return inspector.calls.load(std::memory_order_acquire) == 1; });
  service.verify(model.panes, second.session(), VerifyPaneDescent{2, 1, 1});
  service.schedule(clients);
  check(first.session().connection.read_paused && first.session().descent_running);
  check(second.session().connection.read_paused && !second.session().descent_running);
  ++pane.generation;
  inspector.released.store(true, std::memory_order_release);
  waitUntil([&] {
    service.collect(clients, model.panes);
    return !first.session().pending_descent && !second.session().pending_descent;
  });
  check(first.receive<RequestFailed>().code == FailureCode::pane_not_found);
  check(second.receive<RequestFailed>().code == FailureCode::pane_not_found);
  check(first.session().verified_pane == 0 && second.session().verified_pane == 0);
  check(!first.session().connection.read_paused && !second.session().connection.read_paused);

  inspector.released.store(false, std::memory_order_release);
  service.verify(model.panes, first.session(), VerifyPaneDescent{3, 1, pane.generation});
  service.schedule(clients);
  waitUntil([&] { return inspector.calls.load(std::memory_order_acquire) == 3; });
  first.session().connection.closing = true;
  service.verify(model.panes, second.session(), VerifyPaneDescent{4, 1, pane.generation});
  service.schedule(clients);
  inspector.released.store(true, std::memory_order_release);
  waitUntil([&] {
    service.collect(clients, model.panes);
    return !first.session().pending_descent && !second.session().pending_descent;
  });
  check(!first.session().connection.hasOutput() && first.session().verified_pane == 0);
  check(second.receive<RequestCompleted>().request_id == 4);
  check(second.session().verified_generation == pane.generation);
  check(second.session().verified_lineage.ancestors().front() == pane.process->processId());
}
