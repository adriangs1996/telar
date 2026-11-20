#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/types.h>

import std;
import telar.base.memory.allocators;

import telar.platform.primitives;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.testing;
import telar.testing.test_memory;
import telar.platform.process;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.process_probe;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct GatedLineageInspector {
    mutable std::atomic<unsigned> calls{0};
    mutable std::atomic<bool> released{false};

    ProcessLineage lineage(const ProcessIdentity&, pid_t root) const noexcept {
      calls.fetch_add(1, std::memory_order_release);
      while (!released.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }

      return {.processes = {root}, .count = 1, .descends = true};
    }
  };

  template <typename Condition>
  void waitUntil(Condition&& condition) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};

    while (!condition()) {
      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }
  }

  void testDescent() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

    model.panes.insert(1, ds::makeBox<Pane>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
    auto& pane = *model.panes.find(1);
    GatedLineageInspector inspector;
    DescentService<decltype(inspector)> service{inspector};
    ClientPeer first{memory, model, clients, ClientRole::control};
    ClientPeer second{memory, model, clients, ClientRole::control};

    first.session().peer_identity = ProcessIdentity{41};
    second.session().peer_identity = ProcessIdentity{42};
    service.verify(model.panes, first.session(), VerifyPaneDescent{1, 1, 1});
    service.schedule(clients);
    waitUntil([&] {
      return inspector.calls.load(std::memory_order_acquire) == 1;
    });

    service.verify(model.panes, second.session(), VerifyPaneDescent{2, 1, 1});
    service.schedule(clients);
    ++pane.generation;
    inspector.released.store(true, std::memory_order_release);
    waitUntil([&] {
      service.collect(clients, model.panes);
      return !first.session().pending_descent && !second.session().pending_descent;
    });

    check(first.receive<RequestFailed>().code == FailureCode::pane_not_found);
    check(second.receive<RequestFailed>().code == FailureCode::pane_not_found);
    check(first.session().verified_pane == 0 && second.session().verified_pane == 0);
    check(!first.session().connection.flags().read_paused && !second.session().connection.flags().read_paused);

    inspector.released.store(false, std::memory_order_release);
    service.verify(model.panes, first.session(), VerifyPaneDescent{3, 1, pane.generation});
    service.schedule(clients);
    waitUntil([&] {
      return inspector.calls.load(std::memory_order_acquire) == 3;
    });

    first.session().connection.flagsMut().closing = true;
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

  // Blocks the inspection of the first process it sees until released; any other answers at once.
  struct FirstGatedInspector {
    mutable std::atomic<unsigned> calls{0};
    mutable std::atomic<bool> released{false};

    ProcessLineage lineage(const ProcessIdentity& identity, pid_t root) const noexcept {
      calls.fetch_add(1, std::memory_order_release);
      while (identity.pid == 41 && !released.load(std::memory_order_acquire)) {
        std::this_thread::yield();
      }

      return {.processes = {root}, .count = 1, .descends = true};
    }
  };

  void testOneInspectionAtATime() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

    model.panes.insert(1, ds::makeBox<Pane>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
    const auto generation = model.panes.find(1)->generation;
    FirstGatedInspector inspector;
    DescentService<decltype(inspector)> service{inspector};
    ClientPeer first{memory, model, clients, ClientRole::control};
    ClientPeer second{memory, model, clients, ClientRole::control};

    first.session().peer_identity = ProcessIdentity{41};
    second.session().peer_identity = ProcessIdentity{42};
    service.verify(model.panes, first.session(), VerifyPaneDescent{1, 1, generation});
    service.schedule(clients);
    waitUntil([&] {
      return inspector.calls.load(std::memory_order_acquire) == 1;
    });

    // The second check is asked for while the first runs; both must be answered, each its own.
    service.verify(model.panes, second.session(), VerifyPaneDescent{2, 1, generation});
    service.schedule(clients);
    inspector.released.store(true, std::memory_order_release);
    std::this_thread::sleep_for(std::chrono::milliseconds{100});
    waitUntil([&] {
      service.collect(clients, model.panes);
      return !first.session().pending_descent && !second.session().pending_descent;
    });

    check(first.receive<RequestCompleted>().request_id == 1);
    check(second.receive<RequestCompleted>().request_id == 2);
  }

  const telar::testing::Case case_descent{"descent.descent", testDescent};
  const telar::testing::Case case_one_inspection_at_a_time{"descent.one_inspection_at_a_time", testOneInspectionAtATime};

}
