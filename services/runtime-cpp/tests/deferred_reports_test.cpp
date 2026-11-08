#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "client_peer.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <cstddef>
#include <stdexcept>
#include "../diagnostics/line.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/memory/allocator.hpp"
#include <bit>
#include <concepts>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
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
#include "telar_platform/trace.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <atomic>
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



import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

struct RecordedAgents {
  Agent current{1, 1};

  const Agent *find(std::uint64_t pane, std::uint64_t generation) const noexcept {
    return pane == current.pane && generation == current.generation ? &current : nullptr;
  }
};

struct ReporterFixture {
  SystemAllocator memory;
  RuntimeModel<SystemAllocator> model{memory};
  ClientStore<SystemAllocator> clients{memory};
  RecordedAgents agents;
  DeferredReports<SystemAllocator, RecordedAgents> reports;
  ClientPeer first{memory, model, clients, ClientRole::control};
  ClientPeer second{memory, model, clients, ClientRole::control};
  ReporterIdentity reporter{1, 1, AgentProvider::codex};

  ReporterFixture() {
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    model.panes.insert(1, makeOwned<Pane<SystemAllocator>>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
    agents.current.observeProcess(ProcessIdentity{42, 1, 1, 0, 42}, AgentProvider::claude);
    agents.current.setProcessContext(SessionHost::pane, false, agents.current.process_identity);
    for (auto *client : {&first.session(), &second.session()}) {
      client->verified_pane = 1;
      client->verified_generation = 1;
      client->verified_lineage = {.processes = {81, 70, 42}, .count = 3, .descends = true};
    }
  }

  Pane<SystemAllocator> &pane() const {
    return *model.panes.find(1);
  }

  // Answers the due reports as the runtime does: each payload leaves its client while it runs.
  template <typename Consumer>
  void answerDue(ObservationTime now, Consumer &&consume) {
    const auto due = reports.due(clients, model.panes, agents, now);
    for (const auto identity : due.ids()) {
      auto &client = *clients.find(identity);
      Vector<Byte, SystemAllocator> payload{AllocatorRef<Byte, SystemAllocator>{memory}};
      reports.open(client, payload);
      if (!client.connection.closing) {
        consume(client, std::span<const Byte>{payload});
      }
      DeferredReports<SystemAllocator, RecordedAgents>::close(client, payload);
    }
  }

  ReportDecision evaluate(ClientSession<SystemAllocator> &client, std::span<const Byte> payload) {
    return reports.evaluate(model.panes, agents, client, reporter, payload);
  }
};

static void testRecheckAndRejection() {
  ReporterFixture fixture;
  auto &client = fixture.first.session();
  const std::array<Byte, 2> payload{1, 2};
  check(fixture.evaluate(client, payload) == ReportDecision::deferred);
  check(client.connection.read_paused && fixture.pane().process_recheck_requested);
  unsigned answered = 0;
  const auto receive = [&](auto &session, auto bytes) {
    ++answered;
    check(std::ranges::equal(bytes, payload));
    check(fixture.evaluate(session, bytes) == ReportDecision::rejected);
  };
  fixture.answerDue(ObservationTime::now(), receive);
  check(answered == 0);
  ++fixture.pane().process_rechecks;
  fixture.answerDue(ObservationTime::now(), receive);
  check(answered == 1 && !client.connection.read_paused);
  check(fixture.pane().rejected_reporter == std::optional{RejectedReporter{42, 42, 70}});
  check(fixture.evaluate(client, payload) == ReportDecision::rejected);

  client.verified_lineage = {.processes = {42}, .count = 1, .descends = true};
  check(fixture.evaluate(client, payload) == ReportDecision::deferred);
  fixture.reports.cancel(client);
}

static void testRecheckOrderingAndOwnedPayload() {
  ReporterFixture fixture;
  auto &first = fixture.first.session();
  auto &second = fixture.second.session();
  std::array<Byte, 2> payload{3, 4};
  fixture.pane().process_recheck_running = true;
  check(fixture.evaluate(second, payload) == ReportDecision::deferred);
  check(fixture.evaluate(first, payload) == ReportDecision::deferred);
  check(first.deferred_report.required_recheck == 2);
  payload.fill(0);
  const auto first_time = first.deferred_report.observed;
  std::vector<std::uint64_t> order;
  const auto receive = [&](auto &client, auto bytes) {
    order.push_back(client.id);
    check(bytes.size() == 2 && bytes[0] == 3 && bytes[1] == 4);
    check(client.deferred_report.reportTime().nanoseconds == client.deferred_report.observed.nanoseconds);
    check(fixture.evaluate(client, bytes) == ReportDecision::accepted);
  };
  fixture.pane().process_rechecks = 1;
  fixture.answerDue(ObservationTime::now(), receive);
  check(order.empty());
  fixture.agents.current.observeProcess(ProcessIdentity{43, 1, 2, 0, 42}, AgentProvider::codex);
  fixture.answerDue(ObservationTime::now(), receive);
  check(order == std::vector<std::uint64_t>{second.id, first.id});
  check(first.deferred_report.observed.nanoseconds == first_time.nanoseconds);
  check(!first.deferred_report.pending && !first.deferred_report.answering);
  check(first.deferred_report.payload.empty());
}

static void testTimeoutAndClosedPane() {
  ReporterFixture fixture;
  auto &client = fixture.first.session();
  const std::array<Byte, 1> payload{7};
  check(fixture.evaluate(client, payload) == ReportDecision::deferred);
  auto now = client.deferred_report.observed;
  now.nanoseconds += 2'000'000'000;
  unsigned answered = 0;
  fixture.answerDue(now, [&](auto &session, auto bytes) {
    ++answered;
    check(!session.deferred_report.answer_rechecked);
    check(fixture.evaluate(session, bytes) == ReportDecision::rejected);
  });
  check(answered == 1 && !fixture.pane().rejected_reporter);
  check(fixture.evaluate(client, payload) == ReportDecision::deferred);
  fixture.pane().exit_status = 0;
  fixture.answerDue(ObservationTime::now(), [&](auto &, auto) { ++answered; });
  check(answered == 2);

  fixture.pane().exit_status.reset();
  check(fixture.evaluate(client, payload) == ReportDecision::deferred);
  fixture.reports.cancel(client);
  ++fixture.pane().process_rechecks;
  fixture.answerDue(ObservationTime::now(), [&](auto &, auto) { check(false); });
  DeferredReport<SystemAllocator> wrapping{fixture.memory};
  wrapping.required_recheck = UINT32_MAX;
  check(wrapping.rechecked(0) && !wrapping.rechecked(UINT32_MAX - 1));
}

void testDeferredReports() {
  testRecheckAndRejection();
  testRecheckOrderingAndOwnedPayload();
  testTimeoutAndClosedPane();
}
