#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "cell_layout.hpp"
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
#include <poll.h>
#include <sys/stat.h>

import std;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.client_peer;
import telar.runtime.runtime.execution_service;
import telar.runtime.runtime.runtime;
import telar.wire.clients;
import telar.wire.execution;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.runtime.tests.check;

using namespace telar;
using namespace telar::runtime;

static void testLimits(ConcurrentMemory& memory) {
  RuntimeModel model{memory};
  ClientStore<ConcurrentMemory> clients{memory};
  LimitService<ConcurrentMemory> limits;
  ClientPeer reporter{memory, model, clients, ClientRole::control};
  ClientPeer observer{memory, model, clients, ClientRole::interactive};
  const ReportLimit report{.reach = {.name = "test.capacity", .noun = "items", .value = 10, .requested = 11, .route = "testing"}, .hits = 3};

  limits.receive(model.limits, reporter.session(), report);
  limits.deliver(model, clients);
  check(observer.receive<Notification>().message == "test.capacity: 11 items; limit 10 (3 times)");
  for (unsigned index = 0; index < 32; ++index) {
    limits.receive(model.limits, reporter.session(), report);
  }

  limits.query(reporter.session(), QueryLimits{.request_id = 1});
  const auto listed = reporter.receive<LimitList>();

  check(listed.entries.size() == 1);
  check(listed.entries[0].hits == 96 && listed.refused_reports == 1);
  check(listed.entries[0].reach.requested == 11);
  check(listed.entries[0].origin == LimitOrigin::client);

  LimitLedger ledger;

  for (unsigned index = 0; index <= LimitLedger::capacity; ++index) {
    std::array<char, 32> name;
    const int length = std::snprintf(name.data(), name.size(), "limit_%u", index);

    ledger.record(LimitReach{.name = {name.data(), static_cast<std::size_t>(length)}}, 1);
  }

  check(ledger.rows().size() == LimitLedger::capacity && ledger.evicted() == 1);
}

static void testWorktreeOwnership(ConcurrentMemory& memory) {
  Worktrees worktrees{memory};
  RegisterWorktree request{.request_id = 1, .source = 5, .path = "/tmp/worktree", .branch = "feature", .title = "Initial"};
  const auto added = worktrees.registerEntry(request);

  check(added.created);
  request.title = "Updated";
  const auto repeated = worktrees.registerEntry(request);

  check(!repeated.created && repeated.worktree == added.worktree);
  check(worktrees.find(added.worktree)->title.view() == "Updated");
  check(worktrees.containing("/tmp/worktree/src") != nullptr);
  check(worktrees.containing("/tmp/worktree-other") == nullptr);
  worktrees.remove(added.worktree);
  check(worktrees.find(added.worktree) == nullptr);
  check(worktrees.registerEntry(request).worktree != added.worktree);
}

static void testExecutions(ConcurrentMemory& memory) {
  RuntimeModel model{memory};
  ClientStore<ConcurrentMemory> clients{memory};
  LimitService<ConcurrentMemory> limits;
  NativeEventLoop<ConcurrentMemory> poller{memory};
  ExecutionService executions{memory, poller, limits};
  ClientPeer owner{memory, model, clients, ClientRole::control};
  ClientPeer outsider{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "cat; printf error >&2; exit 17"};
  ExecutionRequest request{.request_id = 1, .action = ExecutionAction::start, .execution_id = 73, .stdin_open = true, .cwd = "/tmp", .arguments = arguments};

  executions.request(model, owner.session(), request);
  check(owner.receive<ExecutionReply>().state == ExecutionState::starting);
  request.request_id = 2;
  executions.request(model, owner.session(), request);
  check(owner.receive<ExecutionReply>().execution_id == 73);
  request.cwd = "/";
  bool conflict = false;

  try {
    executions.request(model, owner.session(), request);
  } catch (const RequestError& error) {
    conflict = error.code() == FailureCode::invalid_request;
  }

  check(conflict);

  request = {.request_id = 3, .action = ExecutionAction::input, .execution_id = 73};
  const std::array<Byte, 6> bytes{'h', 'e', 'l', 'l', 'o', '\n'};

  request.bytes = bytes;
  bool refused = false;

  try {
    executions.request(model, outsider.session(), request);
  } catch (const RequestError&) {
    refused = true;
  }

  check(refused);
  executions.request(model, owner.session(), request);
  check(owner.receive<ExecutionReply>().input_offset == bytes.size());
  executions.request(model, owner.session(), request);
  check(owner.receive<ExecutionReply>().input_offset == bytes.size());
  executions.disconnect(owner.session().id);

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  std::array<Event, decltype(poller)::event_capacity> ready{};

  while (executions.refresh(model)) {
    check(std::chrono::steady_clock::now() < deadline);
    for (const auto& event : poller.wait(std::chrono::milliseconds{10}, ready)) {
      executions.event(event);
    }
  }

  request = {.request_id = 4, .action = ExecutionAction::status, .execution_id = 73};
  executions.request(model, outsider.session(), request);
  const auto result = outsider.receive<ExecutionReply>();

  check(result.state == ExecutionState::exited && result.exit_code == 17);
  check(std::string_view{reinterpret_cast<const char*>(result.stdout_bytes.data()), result.stdout_bytes.size()} == "hello\n");
  check(std::string_view{reinterpret_cast<const char*>(result.stderr_bytes.data()), result.stderr_bytes.size()} == "error");
  check(!result.stdin_open);
  request.action = ExecutionAction::forget;
  executions.request(model, outsider.session(), request);
  outsider.receive<ExecutionReply>();
  request.action = ExecutionAction::list;
  request.execution_id = 0;
  executions.request(model, outsider.session(), request);
  check(outsider.receive<ExecutionReply>().execution_id == 0);

  RetainedStream retained{memory, 4};

  retained.append(bytes);
  std::array<Byte, 8> output;
  const auto tail = retained.read(2, output);

  check(tail.size() == 4 && tail[0] == 'l' && tail[3] == '\n');
  check(retained.retainedOffset() == 2 && retained.total() == 6);
}

void testControlServices() {
  SystemAllocator system;
  MemoryAdapter adapter{system};
  ConcurrentMemory& memory = adapter;

  testLimits(memory);
  testWorktreeOwnership(memory);
  testExecutions(memory);
}
