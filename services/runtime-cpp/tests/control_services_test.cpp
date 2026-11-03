#include "client_peer.hpp"
#include "runtime/execution_service.hpp"
#include "runtime/limit_service.hpp"
#include "runtime/worktree_service.hpp"
#include <thread>

using namespace telar;
using namespace telar::runtime;

static void testLimits(SystemAllocator &memory) {
  RuntimeModel model{memory};
  LimitService limits{model};
  ClientPeer reporter{memory, model, ClientRole::control};
  ClientPeer observer{memory, model, ClientRole::interactive};
  const ReportLimit report{.reach = {.name = "test.capacity",
                                     .noun = "items",
                                     .value = 10,
                                     .requested = 11,
                                     .route = "testing"},
                           .hits = 3};
  limits.receive(reporter.session(), report);
  check(observer.receive<Notification>().message == "test.capacity: 11 items; limit 10 (3 times)");
  for (unsigned index = 0; index < 32; ++index) {
    limits.receive(reporter.session(), report);
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

static void testWorktreeOwnership(SystemAllocator &memory) {
  Worktrees worktrees{memory};
  RegisterWorktree request{.request_id = 1,
                           .source = 5,
                           .path = "/tmp/worktree",
                           .branch = "feature",
                           .title = "Initial"};
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

static void testExecutions(SystemAllocator &memory) {
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  LimitService limits{model};
  ExecutionService executions{memory, model, poller, limits};
  ClientPeer owner{memory, model, ClientRole::control};
  ClientPeer outsider{memory, model, ClientRole::control};
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "cat; printf error >&2; exit 17"};
  ExecutionRequest request{.request_id = 1,
                           .action = ExecutionAction::start,
                           .execution_id = 73,
                           .stdin_open = true,
                           .cwd = "/tmp",
                           .arguments = arguments};
  executions.request(owner.session(), request);
  check(owner.receive<ExecutionReply>().state == ExecutionState::starting);
  request.request_id = 2;
  executions.request(owner.session(), request);
  check(owner.receive<ExecutionReply>().execution_id == 73);
  request.cwd = "/";
  bool conflict = false;
  try {
    executions.request(owner.session(), request);
  } catch (const RequestError &error) {
    conflict = error.code() == FailureCode::invalid_request;
  }
  check(conflict);

  request = {.request_id = 3,
             .action = ExecutionAction::input,
             .execution_id = 73};
  const std::array<Byte, 6> bytes{'h', 'e', 'l', 'l', 'o', '\n'};
  request.bytes = bytes;
  bool refused = false;
  try {
    executions.request(outsider.session(), request);
  } catch (const RequestError &) {
    refused = true;
  }
  check(refused);
  executions.request(owner.session(), request);
  check(owner.receive<ExecutionReply>().input_offset == bytes.size());
  executions.request(owner.session(), request);
  check(owner.receive<ExecutionReply>().input_offset == bytes.size());
  executions.disconnect(owner.session().id);

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (executions.refresh()) {
    check(std::chrono::steady_clock::now() < deadline);
    for (const auto &event : poller.wait(std::chrono::milliseconds{10})) {
      executions.event(event);
    }
  }

  request = {.request_id = 4,
             .action = ExecutionAction::status,
             .execution_id = 73};
  executions.request(outsider.session(), request);
  const auto result = outsider.receive<ExecutionReply>();
  check(result.state == ExecutionState::exited && result.exit_code == 17);
  check(std::string_view{reinterpret_cast<const char *>(result.stdout_bytes.data()), result.stdout_bytes.size()} == "hello\n");
  check(std::string_view{reinterpret_cast<const char *>(result.stderr_bytes.data()), result.stderr_bytes.size()} == "error");
  check(!result.stdin_open);
  request.action = ExecutionAction::forget;
  executions.request(outsider.session(), request);
  outsider.receive<ExecutionReply>();
  request.action = ExecutionAction::list;
  request.execution_id = 0;
  executions.request(outsider.session(), request);
  check(outsider.receive<ExecutionReply>().execution_id == 0);

  RetainedStream retained{memory, 4};
  retained.append(bytes);
  std::array<Byte, 8> output;
  const auto tail = retained.read(2, output);
  check(tail.size() == 4 && tail[0] == 'l' && tail[3] == '\n');
  check(retained.retainedOffset() == 2 && retained.total() == 6);
}

void testControlServices() {
  SystemAllocator memory;
  testLimits(memory);
  testWorktreeOwnership(memory);
  testExecutions(memory);
}
