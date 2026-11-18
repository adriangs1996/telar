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
#include <poll.h>
#include <sys/stat.h>

import std;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.execution_service;
import telar.wire.clients;
import telar.wire.execution;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.wire.worktrees;
import telar.testing;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.event_loop;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testLimits(ConcurrentMemory& memory) {
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
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
      ds::Array<char, 32> name;
      const int length = std::snprintf(name.dataMut(), name.size(), "limit_%u", index);

      ledger.record(LimitReach{.name = {name.data(), static_cast<std::size_t>(length)}}, 1);
    }

    check(ledger.rows().size() == LimitLedger::capacity && ledger.evicted() == 1);
  }

  void testWorktreeOwnership(ConcurrentMemory& memory) {
    Worktrees worktrees{memory};
    RegisterWorktree request{.request_id = 1, .source = 5, .path = "/tmp/worktree", .branch = "feature", .title = "Initial"};
    const auto added = worktrees.registerEntry(request);

    check(added.created);
    request.title = "Updated";
    const auto repeated = worktrees.registerEntry(request);

    check(!repeated.created && repeated.worktree == added.worktree);
    check(worktrees.find(added.worktree)->title.view() == "Updated");

    // A dispatch that registers the path again links it to its new brief and coordinator, and a
    // request without a title keeps the one it has.
    request.title = {};
    request.brief = "Fix the parser";
    request.coordinator = CoordinatorReference{.session_id = {9}, .pane_id = 4, .pane_generation = 2};
    const auto dispatched = worktrees.registerEntry(request);
    const auto* entry = worktrees.find(added.worktree);

    check(!dispatched.created && dispatched.worktree == added.worktree);
    check(entry->title.view() == "Updated" && entry->brief.view() == "Fix the parser");
    check(entry->coordinator && entry->coordinator->pane_id == 4 && entry->coordinator->pane_generation == 2);
    request.title = "Updated";
    request.brief = {};
    request.coordinator.reset();
    check(worktrees.containing("/tmp/worktree/src") != nullptr);
    check(worktrees.containing("/tmp/worktree-other") == nullptr);
    worktrees.remove(added.worktree);
    check(worktrees.find(added.worktree) == nullptr);
    check(worktrees.registerEntry(request).worktree != added.worktree);
  }

  void testExecutions(ConcurrentMemory& memory) {
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    ExecutionService executions{memory, poller, limits};
    ClientPeer owner{memory, model, clients, ClientRole::control};
    ClientPeer outsider{memory, model, clients, ClientRole::control};
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "cat; printf error >&2; exit 17"};
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
    const ds::Array<Byte, 6> bytes{'h', 'e', 'l', 'l', 'o', '\n'};

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
    ds::Array<Event, decltype(poller)::event_capacity> ready{};

    while (executions.refresh(model)) {
      check(std::chrono::steady_clock::now() < deadline);
      for (const auto& event : poller.wait(std::chrono::milliseconds{10}, ready.viewMut())) {
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
    ds::Array<Byte, 8> output;
    const auto tail = retained.read(2, output.viewMut());

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

  // The code a request was refused with, and its message, or nothing when it was accepted.
  template <typename Service, typename Model>
  ds::Option<std::pair<FailureCode, std::string>> refusal(Service& executions, Model& model, ClientPeer& owner, const ExecutionRequest& request) {
    try {
      executions.request(model, owner.session(), request);
      owner.receive<ExecutionReply>();
      return ds::none;
    } catch (const RequestError& error) {
      return std::pair{error.code(), std::string{error.what()}};
    }
  }

  // Runs the service's children until none is running.
  template <typename Service, typename Model, typename Poller>
  void settleExecutions(Service& executions, Model& model, Poller& poller) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
    ds::Array<Event, Poller::event_capacity> ready{};

    while (executions.refresh(model)) {
      check(std::chrono::steady_clock::now() < deadline);
      for (const auto& event : poller.wait(std::chrono::milliseconds{10}, ready.viewMut())) {
        executions.event(event);
      }
    }
  }

  void testExecutionCapacity() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    ExecutionService executions{memory, poller, limits};
    ClientPeer owner{memory, model, clients, ClientRole::control};
    const ds::Array<std::string_view, 1> done{"/usr/bin/true"};
    const auto start = [&](std::uint64_t identity) {
      return refusal(executions, model, owner, ExecutionRequest{.request_id = identity, .action = ExecutionAction::start, .execution_id = identity, .cwd = "/tmp", .arguments = done});
    };

    // Finished executions stay until their client forgets them, up to the service's capacity.
    std::uint64_t identity = 1;

    for (ds::Option<std::pair<FailureCode, std::string>> refused; identity <= 64 && !(refused = start(identity)); ++identity) {
    }

    const auto retained = identity - 1;

    settleExecutions(executions, model, poller);
    const auto past = start(1000);

    check(retained >= 1 && retained < 64 && past && past->first == FailureCode::resource_limit, "an execution past the capacity was started");

    // Forgetting one makes room for the next.
    check(!refusal(executions, model, owner, ExecutionRequest{.request_id = 2000, .action = ExecutionAction::forget, .execution_id = 1}));
    check(!start(1001), "a forgotten execution kept its place");
  }

  void testAdministrationWorkspaceFromHome() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    ExecutionService executions{memory, poller, limits};
    ClientPeer owner{memory, model, clients, ClientRole::control};
    ds::Array<char, 64> home{};

    std::strcpy(home.dataMut(), "/tmp/telar-home-XXXXXX");
    check(::mkdtemp(home.dataMut()) != nullptr);
    const auto canonical = std::filesystem::canonical(home.data()).string();

    // An execution with no workspace and no directory runs in the user's home.
    check(::setenv("HOME", canonical.c_str(), 1) == 0);
    const ds::Array<std::string_view, 2> pwd{"/bin/pwd", "-P"};

    check(!refusal(executions, model, owner, ExecutionRequest{.request_id = 1, .action = ExecutionAction::start, .execution_id = 1, .arguments = pwd}));
    settleExecutions(executions, model, poller);
    executions.request(model, owner.session(), ExecutionRequest{.request_id = 2, .action = ExecutionAction::status, .execution_id = 1});
    const auto status = owner.receive<ExecutionReply>();

    check(std::string_view{reinterpret_cast<const char*>(status.stdout_bytes.data()), status.stdout_bytes.size()} == canonical + "\n");
    check(model.workspaces.size() == 0, "the workspace made for the execution outlived it");

    // Without a home there is nowhere to run it.
    check(::unsetenv("HOME") == 0);
    const auto refused = refusal(executions, model, owner, ExecutionRequest{.request_id = 3, .action = ExecutionAction::start, .execution_id = 2, .arguments = pwd});

    check(refused && refused->first == FailureCode::invalid_request);
    std::filesystem::remove_all(canonical);
  }

  void testExecutionInputRefusals() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    LimitService limits;
    NativeEventLoop<ConcurrentMemory> poller{memory};
    ExecutionService executions{memory, poller, limits};
    ClientPeer owner{memory, model, clients, ClientRole::control};
    const ds::Array<std::string_view, 1> echo{"/bin/cat"};

    executions.request(model, owner.session(), ExecutionRequest{.request_id = 1, .action = ExecutionAction::start, .execution_id = 81, .stdin_open = true, .cwd = "/tmp", .arguments = echo});
    owner.receive<ExecutionReply>();
    const auto input = [&](std::uint64_t request, std::uint64_t offset, std::string_view text) {
      return refusal(executions, model, owner, ExecutionRequest{.request_id = request, .action = ExecutionAction::input, .execution_id = 81, .input_offset = offset, .bytes = {reinterpret_cast<const Byte*>(text.data()), text.size()}});
    };

    check(!input(2, 0, "ab"));
    // Past what was written, overlapping and longer, and after the end of input: refused.
    check(input(3, 5, "gap")->first == FailureCode::invalid_request);
    check(input(4, 1, "xyz")->first == FailureCode::invalid_request);
    check(!input(5, 2, "cd\n"));
    check(!refusal(executions, model, owner, ExecutionRequest{.request_id = 6, .action = ExecutionAction::eof, .execution_id = 81}));
    check(input(7, 5, "late")->first == FailureCode::invalid_request);

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
    ds::Array<Event, decltype(poller)::event_capacity> ready{};

    while (executions.refresh(model)) {
      check(std::chrono::steady_clock::now() < deadline);
      for (const auto& event : poller.wait(std::chrono::milliseconds{10}, ready.viewMut())) {
        executions.event(event);
      }
    }

    // The child read exactly what was accepted, in order.
    executions.request(model, owner.session(), ExecutionRequest{.request_id = 8, .action = ExecutionAction::status, .execution_id = 81});
    const auto status = owner.receive<ExecutionReply>();

    check(std::string_view{reinterpret_cast<const char*>(status.stdout_bytes.data()), status.stdout_bytes.size()} == "abcd\n");

    // A child that does not read fills its queue; the CLI retries on exactly this refusal.
    const ds::Array<std::string_view, 3> stalled{"/bin/sh", "-c", "exec sleep 30"};

    executions.request(model, owner.session(), ExecutionRequest{.request_id = 9, .action = ExecutionAction::start, .execution_id = 82, .stdin_open = true, .cwd = "/tmp", .arguments = stalled});
    owner.receive<ExecutionReply>();
    const std::string chunk(4096, 'x');
    std::uint64_t offset = 0;
    ds::Option<std::pair<FailureCode, std::string>> busy;

    for (std::uint64_t request = 10; !busy && request < 10'000; ++request) {
      busy = refusal(executions, model, owner, ExecutionRequest{.request_id = request, .action = ExecutionAction::input, .execution_id = 82, .input_offset = offset, .bytes = {reinterpret_cast<const Byte*>(chunk.data()), chunk.size()}});
      if (!busy) {
        offset += chunk.size();
      }
    }

    check(busy && busy->second == "ExecutionBusy");
    executions.request(model, owner.session(), ExecutionRequest{.request_id = 10'001, .action = ExecutionAction::cancel, .execution_id = 82});
  }

  const telar::testing::Case case_control_services{"control_services.control_services", testControlServices};
  const telar::testing::Case case_execution_input_refusals{"control_services.execution_input_refusals", testExecutionInputRefusals};
  const telar::testing::Case case_execution_capacity{"control_services.execution_capacity", testExecutionCapacity};
  const telar::testing::Case case_administration_workspace_from_home{"control_services.administration_workspace_from_home", testAdministrationWorkspaceFromHome};

}
