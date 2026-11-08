#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#if (TELAR_DIAGNOSTICS)
#include "telar_base/diagnostics/config.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/types.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cstdint>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cassert>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cstring>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cstddef>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cerrno>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cstdio>
#endif
#if (TELAR_DIAGNOSTICS)
#include <cstdlib>
#endif
#if (TELAR_DIAGNOSTICS)
#include <fcntl.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/mman.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <unistd.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include "cell_layout.hpp"
#endif
#if (TELAR_DIAGNOSTICS)
#include <limits.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <csignal>
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/uio.h>
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/wait.h>
#endif
#include <cstdint>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <cerrno>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <csignal>
#endif
#if (defined(__linux__))
#include <fcntl.h>
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
#include <unistd.h>
#endif
#include <cstdlib>
#include <new>
#include <cstdio>
#include <sys/wait.h>
#include <csignal>
#include <sys/stat.h>



#if (TELAR_DIAGNOSTICS)
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
import telar.runtime.diagnostics.runtime_telemetry;
#endif
import telar.runtime.runtime.runtime;

using namespace telar;
using namespace telar::runtime;

void testInputCapacity() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/input-capacity.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer owner{memory, model, clients, ClientRole::interactive};
  ClientPeer control{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, owner.session().id, OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  const std::vector<Byte> retained(Pane<SystemAllocator>::input_limit, 'a');
  pane.input.append(retained);
  const auto revision = pane.input_revision;
  unsigned observations = 0;
  const auto observe = [&](const auto &, std::span<const Byte>) { ++observations; };
  const std::array<Byte, 3> rejected{'b', 'a', 'd'};
  panes.input(model, clients, owner.session().id, PaneInput{pane.id, rejected}, observe);
  limits.deliver(model, clients);
  check(owner.receive<Notification>().message == "panes.input_queue_capacity: 131075 queued input bytes; limit 131072");
  check(pane.input.readable().size() == retained.size() && std::equal(retained.begin(), retained.end(), pane.input.readable().begin()));
  check(pane.input_revision == revision && observations == 0 && !pane.last_input);
  check(owner.session().last_input_pane == pane.id && owner.session().last_input_sequence == 1);

  constexpr std::string_view paste_mode = "\x1b[?2004h";
  pane.terminal.feed({reinterpret_cast<const Byte *>(paste_mode.data()), paste_mode.size()});
  panes.sendText(model.panes, control.session(), SendPaneText{.request_id = 2, .pane_id = pane.id, .mode = PaneTextMode::prompt, .text = "new"}, {}, observe);
  const auto failure = control.receive<RequestFailed>();
  check(failure.request_id == 2 && failure.code == FailureCode::resource_limit);
  check(failure.message == "the pane's input queue holds its limit of 131072 bytes; the program in it is not reading input");
  check(pane.input_revision == revision && observations == 0 && pane.input.size() == retained.size());

  limits.deliver(model, clients);
  LimitService<SystemAllocator>::query(control.session(), QueryLimits{.request_id = 3});
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
  check(model.input_sequence == 1 && owner.session().last_input_sequence == 1);
  check(control.session().last_input_sequence == 0 && observations == 0);
#if TELAR_DIAGNOSTICS
  check(pane.input_dropped_bytes == std::numeric_limits<std::uint64_t>::max());
#endif

  pane.input.truncate(retained.size() - rejected.size());
  panes.input(model, clients, owner.session().id, PaneInput{pane.id, rejected}, observe);
  check(pane.input_revision == revision + 1 && observations == 1 && pane.last_input);
  check(owner.session().last_input_sequence == 2);
  panes.remove(model, clients, pane.id);
}
