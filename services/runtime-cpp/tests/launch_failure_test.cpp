#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <cstddef>
#include <cstdint>
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <cassert>
#include <type_traits>
#include "telar_base/diagnostics/config.hpp"
#include <condition_variable>
#include <pthread.h>
#include <variant>
#include "telar_platform/trace.hpp"
#include "../diagnostics/timing.hpp"
#include <sqlite3.h>
#include "telar_base/diagnostics/limit_reach.hpp"
#include <bit>
#include <concepts>
#include <unordered_set>
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#endif
#if (TELAR_DIAGNOSTICS)
#include <sys/stat.h>
#endif
#include "../diagnostics/line.hpp"
#include <stdexcept>
#include "telar_client/serializers/telar_messages.hpp"
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
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
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
#include <dirent.h>
#include <sys/stat.h>



import telar.runtime.platform.request_worker;
import telar.runtime.runtime.media_service;
import telar.runtime.runtime.execution_service;
import telar.platform;

using namespace telar;
using namespace telar::runtime;

namespace {

template <typename Worker>
struct QueuedHistory {
  Worker &worker;
  unsigned submissions = 0;
  bool accepting = true;

  bool recordHistory(const HistoryEventView &event) noexcept {
    ++submissions;
    if (!accepting) {
      return false;
    }

    try {
      worker.submitInternal(event);
      return true;
    } catch (...) {
      return false;
    }
  }
};

template <Allocator Memory>
struct FailingPoller : NativeEventLoop<Memory> {
  explicit FailingPoller(Memory &memory, RuntimeModel<Memory> &model) : NativeEventLoop<Memory>(memory), model(model) {}

  void watch(int descriptor, std::uint64_t token) {
    NativeEventLoop<Memory>::watch(descriptor, token);
    for (const auto *pane : model.panes.items()) {
      if (pane != nullptr && pane->process->descriptor() == descriptor) {
        process = pane->process->processId();
        break;
      }
    }

    this->descriptor = descriptor;
    if (fail) {
      throw SystemError{"Injected event registration failure", ENOMEM};
    }
  }

  void remove(int descriptor) noexcept {
    ++removals;
    NativeEventLoop<Memory>::remove(descriptor);
  }

  RuntimeModel<Memory> &model;
  pid_t process = -1;
  int descriptor = -1;
  unsigned removals = 0;
  bool fail = true;
};

template <ConcurrentAllocator Memory>
void checkLaunchRollback(Memory &memory, BackgroundService<Memory> &service) {
  RuntimeModel model{memory};
  FailingPoller poller{memory, model};
  RequestWorker worker{memory, service};
  QueuedHistory history{worker};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/launch-failure.sock"}, history};
  constexpr TabLocation location{.workspace = {.id = 7}, .tab_id = 11};
  constexpr TerminalSize size{80, 24, 0, 0};
  constexpr std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/", .arguments = arguments};
  auto workspace = makeOwned<Workspace<Memory>>(memory, memory, location.workspace.id, "/workspace with spaces", "Failure fixture");
  model.workspaces.insert(location.workspace.id, std::move(workspace));

  for (const bool accepting : {true, false}) {
    history.accepting = accepting;
    bool failed = false;
    try {
      panes.launch(launch, location, size);
    } catch (const SystemError &error) {
      failed = error.code() == ENOMEM;
    }

    check(failed && model.panes.size() == 0);
    check(poller.process > 0 && ::waitpid(poller.process, nullptr, WNOHANG) == -1 && errno == ECHILD);
    check(::fcntl(poller.descriptor, F_GETFD) == -1 && errno == EBADF);
    check(history.submissions == poller.removals);
  }

  check(history.submissions == 2 && model.next_pane_generation == 3);
  history.accepting = true;
  poller.fail = false;
  auto &pane = panes.launch(launch, location, size);
  check(model.panes.size() == 1 && pane.generation == 3 && history.submissions == 2);
  const auto retained_process = pane.process->processId();
  Command command{memory, launch};
  bool registration_failed = false;
  try {
    panes.launch(command, location, size, pane.id);
  } catch (const std::bad_alloc &) {
    registration_failed = true;
  }
  check(registration_failed && history.submissions == 3 && model.panes.size() == 1);
  check(panes.require(pane.id).process->processId() == retained_process && ::kill(retained_process, 0) == 0);
  panes.remove(pane.id);

  constexpr std::array<std::string_view, 1> missing{"/nonexistent/telar-launch-test"};
  bool missing_rejected = false;
  try {
    panes.launch(Launch{.cwd = "/", .arguments = missing}, location, size);
  } catch (const std::exception &) {
    missing_rejected = true;
  }
  check(missing_rejected && history.submissions == 3 && model.panes.size() == 0);
}

template <ConcurrentAllocator Memory>
void checkLaunchPersistence(Memory &memory) {
  TemporaryDirectory directory{"/tmp/telar-launch-history-XXXXXX"};
  const auto path = std::string{directory.path()} + "/history.sqlite";
  {
    BackgroundService service{memory, path.c_str()};
    checkLaunchRollback(memory, service);
  }

  Database database{path.c_str(), DatabaseAccess::read_only};
  Statement row{database, "SELECT pane_id, pane_generation, location_kind, location_id, tab_id, workspace_path, shell, started_at_ms, failed_at_ms, phase, cause FROM launch_attempt ORDER BY id"};
  check(row.next());
  check(row.integer(0) == 1 && row.integer(1) == 1 && row.integer(2) == 0 && row.integer(3) == 7 && row.integer(4) == 11);
  check(row.text(5) == "/workspace with spaces" && row.text(6) == "/bin/cat");
  check(row.integer(7) > 0 && row.integer(8) >= row.integer(7));
  check(row.integer(9) == static_cast<std::int64_t>(LaunchPhase::output_actor) && row.text(10) == "SystemResources");
  check(row.next() && row.integer(0) == 3 && row.integer(1) == 4);
  check(row.integer(9) == static_cast<std::int64_t>(LaunchPhase::pane_registration) && row.text(10) == "OutOfMemory");
  check(row.integer(7) > 0 && row.integer(8) >= row.integer(7));
  check(!row.next());
  Statement sessions{database, "SELECT COUNT(*) FROM session"};
  check(sessions.next() && sessions.integer(0) == 0);
}

template <ConcurrentAllocator Memory>
void checkLaunchEventOwnership(Memory &memory) {
  Database database{":memory:"};
  migrateHistory(database);
  LaunchHistoryWriter writer{database};
  for (const auto phase : {LaunchPhase::pane_registration, LaunchPhase::wait_actor, LaunchPhase::output_actor}) {
    std::string workspace = "/retained/workspace";
    std::string shell = "/retained/shell";
    std::string cause = "RetainedFailureCause";
    const auto identity = static_cast<unsigned>(phase) + 1;
    HistoryEvent owned{memory, HistoryEventView{.kind = HistoryEventKind::launch_failed, .session = {.pane = identity, .started_at_ms = 100, .workspace_path = workspace, .shell = shell}, .finished_at_ms = 200, .failure = {identity, phase, cause}}};
    workspace.assign("modified");
    shell.assign("modified");
    cause.assign("modified");
    writer.persist(owned.view());
  }

  Statement rows{database, "SELECT phase, workspace_path, shell, cause FROM launch_attempt ORDER BY phase"};
  for (std::int64_t phase = 0; phase < 3; ++phase) {
    check(rows.next() && rows.integer(0) == phase);
    check(rows.text(1) == "/retained/workspace" && rows.text(2) == "/retained/shell" && rows.text(3) == "RetainedFailureCause");
  }
  check(!rows.next());
}

}

void testLaunchFailures() {
  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  checkLaunchPersistence(memory);
  checkLaunchEventOwnership(memory);
  check(budget.liveBytes() == 0);
}
