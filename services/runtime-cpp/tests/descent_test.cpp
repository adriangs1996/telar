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
#include <condition_variable>
#include <pthread.h>
#include <thread>



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
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  model.panes.insert(1, makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
  auto &pane = *model.panes.find(1);
  GatedLineageInspector inspector;
  DescentService service{model, inspector};
  ClientPeer first{memory, model, ClientRole::control};
  ClientPeer second{memory, model, ClientRole::control};
  first.session().peer_identity = ProcessIdentity{41};
  second.session().peer_identity = ProcessIdentity{42};
  service.verify(first.session(), VerifyPaneDescent{1, 1, 1});
  waitUntil([&] { return inspector.calls.load(std::memory_order_acquire) == 1; });
  service.verify(second.session(), VerifyPaneDescent{2, 1, 1});
  check(first.session().connection.read_paused && first.session().descent_running);
  check(second.session().connection.read_paused && !second.session().descent_running);
  ++pane.generation;
  inspector.released.store(true, std::memory_order_release);
  waitUntil([&] {
    service.collect();
    return !first.session().pending_descent && !second.session().pending_descent;
  });
  check(first.receive<RequestFailed>().code == FailureCode::pane_not_found);
  check(second.receive<RequestFailed>().code == FailureCode::pane_not_found);
  check(first.session().verified_pane == 0 && second.session().verified_pane == 0);
  check(!first.session().connection.read_paused && !second.session().connection.read_paused);

  inspector.released.store(false, std::memory_order_release);
  service.verify(first.session(), VerifyPaneDescent{3, 1, pane.generation});
  waitUntil([&] { return inspector.calls.load(std::memory_order_acquire) == 3; });
  first.session().connection.closing = true;
  service.verify(second.session(), VerifyPaneDescent{4, 1, pane.generation});
  inspector.released.store(true, std::memory_order_release);
  waitUntil([&] {
    service.collect();
    return !first.session().pending_descent && !second.session().pending_descent;
  });
  check(!first.session().connection.hasOutput() && first.session().verified_pane == 0);
  check(second.receive<RequestCompleted>().request_id == 4);
  check(second.session().verified_generation == pane.generation);
  check(second.session().verified_lineage.ancestors().front() == pane.process->processId());
}
