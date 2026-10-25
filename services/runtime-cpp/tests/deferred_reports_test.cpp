#include "client_peer.hpp"
#include "runtime/deferred_reports.hpp"

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
  RecordedAgents agents;
  DeferredReports<SystemAllocator, RecordedAgents> reports{model, agents};
  ClientPeer first{memory, model, ClientRole::control};
  ClientPeer second{memory, model, ClientRole::control};
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
};

static void testRecheckAndRejection() {
  ReporterFixture fixture;
  auto &client = fixture.first.session();
  const std::array<Byte, 2> payload{1, 2};
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::deferred);
  check(client.connection.read_paused && fixture.pane().process_recheck_requested);
  unsigned answered = 0;
  const auto receive = [&](auto &session, auto bytes) {
    ++answered;
    check(std::ranges::equal(bytes, payload));
    check(fixture.reports.evaluate(session, fixture.reporter, bytes) == ReportDecision::rejected);
  };
  fixture.reports.answerDue(ObservationTime::now(), receive);
  check(answered == 0);
  ++fixture.pane().process_rechecks;
  fixture.reports.answerDue(ObservationTime::now(), receive);
  check(answered == 1 && !client.connection.read_paused);
  check(fixture.pane().rejected_reporter == std::optional{RejectedReporter{42, 42, 70}});
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::rejected);

  client.verified_lineage = {.processes = {42}, .count = 1, .descends = true};
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::deferred);
  fixture.reports.cancel(client);
}

static void testRecheckOrderingAndOwnedPayload() {
  ReporterFixture fixture;
  auto &first = fixture.first.session();
  auto &second = fixture.second.session();
  std::array<Byte, 2> payload{3, 4};
  fixture.pane().process_recheck_running = true;
  check(fixture.reports.evaluate(second, fixture.reporter, payload) == ReportDecision::deferred);
  check(fixture.reports.evaluate(first, fixture.reporter, payload) == ReportDecision::deferred);
  check(first.deferred_report.required_recheck == 2);
  payload.fill(0);
  const auto first_time = first.deferred_report.observed;
  std::vector<std::uint64_t> order;
  const auto receive = [&](auto &client, auto bytes) {
    order.push_back(client.id);
    check(bytes.size() == 2 && bytes[0] == 3 && bytes[1] == 4);
    check(client.deferred_report.reportTime().nanoseconds == client.deferred_report.observed.nanoseconds);
    check(fixture.reports.evaluate(client, fixture.reporter, bytes) == ReportDecision::accepted);
  };
  fixture.pane().process_rechecks = 1;
  fixture.reports.answerDue(ObservationTime::now(), receive);
  check(order.empty());
  fixture.agents.current.observeProcess(ProcessIdentity{43, 1, 2, 0, 42}, AgentProvider::codex);
  fixture.reports.answerDue(ObservationTime::now(), receive);
  check(order == std::vector<std::uint64_t>{second.id, first.id});
  check(first.deferred_report.observed.nanoseconds == first_time.nanoseconds);
  check(!first.deferred_report.pending && !first.deferred_report.answering);
  check(first.deferred_report.payload.empty());
}

static void testTimeoutAndClosedPane() {
  ReporterFixture fixture;
  auto &client = fixture.first.session();
  const std::array<Byte, 1> payload{7};
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::deferred);
  auto now = client.deferred_report.observed;
  now.nanoseconds += 2'000'000'000;
  unsigned answered = 0;
  fixture.reports.answerDue(now, [&](auto &session, auto bytes) {
    ++answered;
    check(!session.deferred_report.answer_rechecked);
    check(fixture.reports.evaluate(session, fixture.reporter, bytes) == ReportDecision::rejected);
  });
  check(answered == 1 && !fixture.pane().rejected_reporter);
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::deferred);
  fixture.pane().exit_status = 0;
  fixture.reports.answerDue(ObservationTime::now(), [&](auto &, auto) { ++answered; });
  check(answered == 2);

  fixture.pane().exit_status.reset();
  check(fixture.reports.evaluate(client, fixture.reporter, payload) == ReportDecision::deferred);
  fixture.reports.cancel(client);
  ++fixture.pane().process_rechecks;
  fixture.reports.answerDue(ObservationTime::now(), [&](auto &, auto) { check(false); });
  DeferredReport<SystemAllocator> wrapping{fixture.memory};
  wrapping.required_recheck = UINT32_MAX;
  check(wrapping.rechecked(0) && !wrapping.rechecked(UINT32_MAX - 1));
}

void testDeferredReports() {
  testRecheckAndRejection();
  testRecheckOrderingAndOwnedPayload();
  testTimeoutAndClosedPane();
}
