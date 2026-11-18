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
import telar.runtime.diagnostics.line;
import telar.runtime.terminal.control;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.runtime;
import telar.testing;
import telar.wire.clients;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.event_loop;
import telar.runtime.runtime.execution_service;
import telar.base.ds;
#if (TELAR_DIAGNOSTICS)
import telar.runtime.runtime.runtime_telemetry;
#endif

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testInputCapacity() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/input-capacity.sock"}};
    WorkspaceService<decltype(poller)> workspaces{memory};
    ClientPeer owner{memory, model, clients, ClientRole::interactive};
    ClientPeer control{memory, model, clients, ClientRole::control};
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};

    workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    const auto opened = owner.receive<PaneOpened>();
    auto& pane = panes.require(model.panes, opened.pane_id);
    const std::vector<Byte> retained(Pane::input_limit, 'a');

    pane.input.append(retained);
    const auto revision = pane.input_revision;
    unsigned observations = 0;
    const auto observe = [&](const auto&, std::span<const Byte>) {
      ++observations;
    };

    const ds::Array<Byte, 3> rejected{'b', 'a', 'd'};

    panes.input(model, clients, owner.session().id, PaneInput{pane.id, rejected}, observe);
    limits.deliver(model, clients);
    owner.receive<Notification>();
    check(pane.input.readable().size() == retained.size() && std::equal(retained.begin(), retained.end(), pane.input.readable().begin()));
    check(observations == 0 && !pane.last_input);
    check(owner.session().last_input_pane == pane.id && owner.session().last_input_sequence == 1);

    constexpr std::string_view paste_mode = "\x1b[?2004h";

    pane.terminal.feed({reinterpret_cast<const Byte*>(paste_mode.data()), paste_mode.size()}, *pane.media);
    panes.sendText(model.panes, control.session(), SendPaneText{.request_id = 2, .pane_id = pane.id, .mode = PaneTextMode::prompt, .text = "new"}, {}, observe);
    const auto failure = control.receive<RequestFailed>();

    check(failure.request_id == 2 && failure.code == FailureCode::resource_limit);
    check(pane.input_revision == revision && observations == 0 && pane.input.size() == retained.size());

    limits.deliver(model, clients);
    LimitService::query(control.session(), QueryLimits{.request_id = 3});
    const auto listed = control.receive<LimitList>();

    check(listed.entries.size() == 1 && listed.entries.front().hits == 2);
    check(listed.entries.front().reach.name == "panes.input_queue_capacity");
    check(listed.entries.front().reach.requested == retained.size() + 16);
#if TELAR_DIAGNOSTICS
    check(pane.input_dropped_bytes == 19);
    diagnostics::Line sample;

    sample.reset();
    diagnostics::writeRuntimeSample(sample, model, clients);
    check(sample.finish().contains("\"pane_input_dropped_bytes\":19"));
    pane.input_dropped_bytes = std::numeric_limits<std::uint64_t>::max() - 1;
#endif

    control.session().last_input_sequence = 7;
    model.input_sequence = std::numeric_limits<std::uint64_t>::max();
    panes.input(model, clients, owner.session().id, PaneInput{pane.id, rejected}, observe);
    check(owner.session().last_input_sequence == 1);
    check(control.session().last_input_sequence == 0 && observations == 0);
#if TELAR_DIAGNOSTICS
    check(pane.input_dropped_bytes == std::numeric_limits<std::uint64_t>::max());
#endif

    pane.input.truncate(retained.size() - rejected.size());
    panes.input(model, clients, owner.session().id, PaneInput{pane.id, rejected}, observe);
    check(observations == 1 && pane.last_input);
    check(owner.session().last_input_sequence == 2);

    // A terminator in typed text cannot close the paste frame and run its tail.
    pane.input.truncate(0);
    std::string observed;
    const auto record = [&](const auto&, std::span<const Byte> bytes) {
      observed.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    };

    panes.sendText(model.panes, control.session(), SendPaneText{.request_id = 4, .pane_id = pane.id, .mode = PaneTextMode::prompt, .text = "a\x1b[201~b"}, {}, record);
    check(control.receive<RequestCompleted>().request_id == 4);
    // The queue was flushed to the pty, so what it received is what the observer saw.
    check(observed == "\x1b[200~a [201~b\x1b[201~\r");
    panes.remove(model, clients, pane.id);
  }

  const telar::testing::Case case_input_capacity{"input_capacity.input_capacity", testInputCapacity};
}
