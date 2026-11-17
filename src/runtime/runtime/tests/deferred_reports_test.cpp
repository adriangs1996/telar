#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/types.h>

import std;
import telar.base.memory.allocators;

import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.runtime.tests.client_peer;
import telar.runtime.runtime.client_control;
import telar.wire.vocabulary;
import telar.testing;
import telar.platform.events;
import telar.platform.process;
import telar.runtime.agents.description_generator;
import telar.runtime.agents.snapshot;
import telar.runtime.model.client_layouts;
import telar.runtime.model.slot_store;
import telar.runtime.platform.session_host;
import telar.runtime.platform.process_probe;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct RecordedAgents {
    Agent current{1, 1};

    const Agent* find(std::uint64_t pane, std::uint64_t generation) const noexcept {
      return pane == current.pane && generation == current.generation ? &current : nullptr;
    }
  };

  struct ReporterFixture {
    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter{system};
    ConcurrentMemory& memory = adapter;
    RuntimeModel model{memory};
    ClientStore clients{memory};
    RecordedAgents agents;
    DeferredReports<RecordedAgents> reports;
    ClientPeer first{memory, model, clients, ClientRole::control};
    ClientPeer second{memory, model, clients, ClientRole::control};
    ReporterIdentity reporter{1, 1, AgentProvider::codex};

    ReporterFixture() {
      const std::array<std::string_view, 1> arguments{"/bin/cat"};
      Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

      model.panes.insert(1, makeOwned<Pane>(memory, memory, 1, TabLocation{}, command, PaneLaunch{TerminalSize{20, 4, 8, 16}, model.media_budget, model.graphics_limits}));
      agents.current.observeProcess(ProcessIdentity{42, 1, 1, 0, 42}, AgentProvider::claude);
      agents.current.setProcessContext(SessionHost::pane, false, agents.current.process_identity);
      for (auto* client : {&first.session(), &second.session()}) {
        client->verified_pane = 1;
        client->verified_generation = 1;
        client->verified_lineage = {.processes = {81, 70, 42}, .count = 3, .descends = true};
      }
    }

    Pane& pane() const {
      return *model.panes.find(1);
    }

    // Answers the due reports as the runtime does: each payload leaves its client while it runs.
    template <typename Consumer>
    void answerDue(ObservationTime now, Consumer&& consume) {
      const auto due = reports.due(clients, model.panes, agents, now);

      for (const auto identity : due.ids()) {
        auto& client = *clients.find(identity);
        Vector<Byte, ConcurrentMemory> payload{AllocatorRef<Byte, ConcurrentMemory>{memory}};

        reports.open(client, payload);
        if (!client.connection.closing) {
          consume(client, std::span<const Byte>{payload});
        }

        DeferredReports<RecordedAgents>::close(client, payload);
      }
    }

    ReportDecision evaluate(ClientSession& client, std::span<const Byte> payload) {
      return reports.evaluate(model.panes, agents, client, reporter, payload);
    }
  };

  void testRecheckAndRejection() {
    ReporterFixture fixture;
    auto& client = fixture.first.session();
    const std::array<Byte, 2> payload{1, 2};

    check(fixture.evaluate(client, payload) == ReportDecision::deferred);
    unsigned answered = 0;
    const auto receive = [&](auto& session, auto bytes) {
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

  void testRecheckOrderingAndOwnedPayload() {
    ReporterFixture fixture;
    auto& first = fixture.first.session();
    auto& second = fixture.second.session();
    std::array<Byte, 2> payload{3, 4};

    fixture.pane().process_recheck_running = true;
    check(fixture.evaluate(second, payload) == ReportDecision::deferred);
    check(fixture.evaluate(first, payload) == ReportDecision::deferred);
    payload.fill(0);
    std::vector<std::uint64_t> order;
    const auto receive = [&](auto& client, auto bytes) {
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
  }

  void testTimeoutAndClosedPane() {
    ReporterFixture fixture;
    auto& client = fixture.first.session();
    const std::array<Byte, 1> payload{7};

    check(fixture.evaluate(client, payload) == ReportDecision::deferred);
    auto now = client.deferred_report.observed;

    now.nanoseconds += 2'000'000'000;
    unsigned answered = 0;

    fixture.answerDue(now, [&](auto& session, auto bytes) {
      ++answered;
      check(!session.deferred_report.answer_rechecked);
      check(fixture.evaluate(session, bytes) == ReportDecision::rejected);
    });

    check(answered == 1 && !fixture.pane().rejected_reporter);
    check(fixture.evaluate(client, payload) == ReportDecision::deferred);
    fixture.pane().exit_status = 0;
    fixture.answerDue(ObservationTime::now(), [&](auto&, auto) {
      ++answered;
    });

    check(answered == 2);

    fixture.pane().exit_status.reset();
    check(fixture.evaluate(client, payload) == ReportDecision::deferred);
    fixture.reports.cancel(client);
    ++fixture.pane().process_rechecks;
    fixture.answerDue(ObservationTime::now(), [&](auto&, auto) {
      check(false);
    });

    DeferredReport<ConcurrentMemory> wrapping{fixture.memory};

    wrapping.required_recheck = UINT32_MAX;
    check(wrapping.rechecked(0) && !wrapping.rechecked(UINT32_MAX - 1));
  }

  const telar::testing::Case case_recheck_and_rejection{"deferred_reports.recheck_and_rejection", testRecheckAndRejection};
  const telar::testing::Case case_recheck_ordering_and_owned_payload{"deferred_reports.recheck_ordering_and_owned_payload", testRecheckOrderingAndOwnedPayload};
  const telar::testing::Case case_timeout_and_closed_pane{"deferred_reports.timeout_and_closed_pane", testTimeoutAndClosedPane};

}
