#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstring>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>
#include <sys/types.h>
#include <cerrno>
#include <unistd.h>
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/stat.h>
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
#include <new>
#include <termios.h>
#include <pthread.h>
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
import telar.runtime.runtime.runtime;
import telar.runtime.runtime.client_control;

using namespace telar;
using namespace telar::runtime;

struct TestProcessInspector {
  AgentProvider active = AgentProvider::claude;
  ProcessIdentity current{71, 1, 10, 0};
  bool descendant = true;
  mutable unsigned descent_checks = 0;

  ProcessLineage lineage(const ProcessIdentity &, pid_t root) const noexcept {
    ++descent_checks;
    return {.processes = {root}, .count = 1, .descends = descendant};
  }
};

template <typename Verification>
static void verifyAndWait(Verification &verification, RuntimeModel<SystemAllocator> &model, ClientStore<SystemAllocator> &clients, ClientPeer &reporter, const VerifyPaneDescent &request) {
  verification.verify(model.panes, reporter.session(), request);
  verification.schedule(clients);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (reporter.session().pending_descent) {
    verification.collect(clients, model.panes);
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::yield();
  }
}

static void feedAgent(Terminal<SystemAllocator> &terminal, std::string_view text) {
  terminal.feed({reinterpret_cast<const Byte *>(text.data()), text.size()});
  terminal.refresh();
}

static void testScreenEvidence(SystemAllocator &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 8, 16}};
  feedAgent(terminal, "\x1b]0;◐ Working\x1b\\\x1b[22;1H❯ ");
  check(AgentScreenReader{terminal}.observe(AgentProvider::claude).status == AgentStatus::working);
  feedAgent(terminal, "\x1b]0;✳ Idle\x1b\\");
  check(AgentScreenReader{terminal}.observe(AgentProvider::claude).status == AgentStatus::ready);
  feedAgent(terminal, "\x1b[22;1H❯ restored prompt");
  check(AgentScreenReader{terminal}.observe(AgentProvider::claude).restored_draft);
  feedAgent(terminal, "\x1b[22;1H\x1b[2K❯ \x1b[2mplaceholder\x1b[0m\x1b[22;3H");
  check(!AgentScreenReader{terminal}.observe(AgentProvider::claude).restored_draft);
  feedAgent(terminal, "\x1b[2J\x1b[20;1HWorking (12s)\x1b[22;1H› ");
  check(AgentScreenReader{terminal}.observe(AgentProvider::codex).status == AgentStatus::working);
  feedAgent(terminal, "\x1b[20;1H\x1b[2K\x1b[22;3H");
  check(AgentScreenReader{terminal}.observe(AgentProvider::codex).status == AgentStatus::ready);
  feedAgent(terminal, "\x1b[2J\x1b[22;1H→ Add a follow-up");
  check(AgentScreenReader{terminal}.observe(AgentProvider::cursor).status == AgentStatus::ready);
  feedAgent(terminal, "\x1b[20;1H⠞ Working");
  check(AgentScreenReader{terminal}.observe(AgentProvider::cursor).status == AgentStatus::working);

  feedAgent(terminal, "\x1b[2J\x1b[?25l\x1b]0;✳ Idle\x1b\\\x1b[20;1H❯ \x1b[7m \x1b[0m\x1b[22;1H❯ restored draft");
  const auto software_cursor = AgentScreenReader{terminal}.observe(AgentProvider::claude);
  check(software_cursor.status == AgentStatus::ready && software_cursor.restored_draft);

  feedAgent(terminal, "\x1b[2J\x1b[?25h\x1b[20;1HWorking (12s)\x1b[22;1H› Ask Codex to do anything\x1b[22;3H");
  const AgentManifests no_manifests;
  check(!AgentScreenReader{terminal, no_manifests}.observe(AgentProvider::codex).status);

  feedAgent(terminal, "\x1b[2J\x1b[1;1H❯        \x1b[1;9H");
  check(!AgentScreenReader{terminal}.observe(AgentProvider::claude).status);
  feedAgent(terminal, "\x1b[1;8H");
  check(AgentScreenReader{terminal}.observe(AgentProvider::claude).status == AgentStatus::ready);
  feedAgent(terminal, "\x1b[1;1H");
  check(AgentScreenReader{terminal}.observe(AgentProvider::claude).status == AgentStatus::ready);

  Terminal wide{memory, TerminalSize{1030, 6, 8, 16}};
  feedAgent(wide, "\x1b[1;1HWorking (1s)\x1b[3;1025H─\x1b[5;1H› ");
  check(AgentScreenReader{wide}.observe(AgentProvider::codex).status == AgentStatus::ready);
}

static void testReportsAndIdentity(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-agent-test.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientLayouts layouts{memory};
  TestProcessInspector inspector;
  AgentService<SystemAllocator, decltype(poller)> agents{memory};
  DescentService<SystemAllocator, decltype(inspector)> verification{inspector};
  ClientPeer reporter{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, reporter.session().id, OpenPane{.request_id = 1,
                                               .size = {80, 24, 8, 16},
                                               .launch = Launch{.cwd = "/tmp",
                                                                .arguments = arguments}});
  const auto opened = reporter.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  reporter.session().peer_identity = inspector.current;
  inspector.descendant = false;
  verifyAndWait(verification, model, clients, reporter, VerifyPaneDescent{2, pane.id, pane.generation});
  check(reporter.receive<RequestFailed>().code == FailureCode::foreign_process);
  inspector.descendant = true;
  verifyAndWait(verification, model, clients, reporter, VerifyPaneDescent{2, pane.id, pane.generation});
  check(reporter.receive<RequestCompleted>().request_id == 2);
  agents.report(model, reporter.session(), ReportAgent{.request_id = 3,
                                                .pane_id = pane.id,
                                                .pane_generation = pane.generation,
                                                .provider = AgentProvider::claude,
                                                .state = AgentReportState::working,
                                                .session = "session-one"});
  reporter.receive<RequestCompleted>();
  const auto now = std::chrono::steady_clock::now();
  agents.observeProcess(pane, inspector.current, inspector.active);
  agents.refresh(model, panes, clients, layouts, now);
  agents.query(model, reporter.session());
  auto snapshot = reporter.receive<AgentSnapshot>();
  check(snapshot.entries.size() == 1 && snapshot.entries[0].status == AgentStatus::working);
  ReportAgent file_report{.request_id = 30, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude, .state = AgentReportState::working, .session = "session-one", .session_file = "/tmp/first-transcript"};
  agents.report(model, reporter.session(), file_report);
  reporter.receive<RequestCompleted>();
  const auto first_probe = agents.nextSessionFile(now);
  check(first_probe.has_value());
  file_report.session_file = "/tmp/second-transcript";
  agents.report(model, reporter.session(), file_report);
  reporter.receive<RequestCompleted>();
  SessionFileResult obsolete{.request = *first_probe, .offset = 10, .title = FixedText<96>{}};
  obsolete.title->assign("Obsolete title");
  agents.completeSessionFile(obsolete, now);
  check(agents.find(pane.id, pane.generation)->title.view().empty());
  const auto second_probe = agents.nextSessionFile(now);
  check(second_probe && second_probe->watch.path.view() == file_report.session_file);
  auto completed = obsolete;
  completed.request = *second_probe;
  completed.title->assign("Current title");
  agents.completeSessionFile(completed, now);
  check(agents.find(pane.id, pane.generation)->title.view() == "Current title");
  check(!agents.nextSessionFile(now + std::chrono::milliseconds{999}));
  check(agents.nextSessionFile(now + std::chrono::seconds{1}).has_value());
  completed.request.generation += 1;
  completed.title->assign("Wrong generation");
  agents.completeSessionFile(completed, now);
  check(agents.find(pane.id, pane.generation)->title.view() == "Current title");
  agents.reportTitle(model, reporter.session(), ReportAgentTitle{.request_id = 31, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude});
  reporter.receive<RequestCompleted>();

  const std::vector<Byte> blocked_input(Pane<SystemAllocator>::input_limit, 'a');
  pane.input.append(blocked_input);
  const auto input_revision = pane.input_revision;
  agents.interrupt(model, panes, reporter.session(), InterruptAgent{4, pane.id, pane.generation}, false);
  check(reporter.receive<RequestCompleted>().request_id == 4);
  check(pane.input.size() == blocked_input.size() && pane.input_revision == input_revision);
  limits.deliver(model, clients);
  check(model.limits.runtime.rows().size() == 1 && model.limits.runtime.rows().front().reach().name == "panes.input_queue_capacity");
#if TELAR_DIAGNOSTICS
  check(pane.input_dropped_bytes > 0);
#endif
  pane.input.clear();
  feedAgent(pane.terminal, "\x1b]0;◐ Working\x1b\\\x1b[22;1H❯ ");
  agents.refresh(model, panes, clients, layouts, now + std::chrono::seconds{4});
  agents.query(model, reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::working);
  feedAgent(pane.terminal, "\x1b]0;✳ Idle\x1b\\");
  agents.refresh(model, panes, clients, layouts, now + std::chrono::seconds{5});
  agents.refresh(model, panes, clients, layouts, now + std::chrono::milliseconds{5600});
  agents.query(model, reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::done);
  agents.acknowledge(AcknowledgeAgent{pane.id, pane.generation});
  agents.query(model, reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::ready);
  inspector.active = AgentProvider::codex;
  ++inspector.current.started_seconds;
  agents.observeProcess(pane, inspector.current, inspector.active);
  agents.refresh(model, panes, clients, layouts, now + std::chrono::seconds{7});
  agents.query(model, reporter.session());
  snapshot = reporter.receive<AgentSnapshot>();
  check(snapshot.entries[0].provider == AgentProvider::codex && snapshot.entries[0].status == AgentStatus::unknown);
  check(snapshot.entries[0].confidence == 100 && snapshot.entries[0].expires_at_ms == INT64_MAX);
  agents.observeProcess(pane, inspector.current, AgentProvider::unknown);
  agents.query(model, reporter.session());
  check(reporter.receive<AgentSnapshot>().entries.empty());
}

static void testProgressAndPromptBudget() {
  AgentProgress progress;
  check(progress.apply(ReportAgentProgress{.plan_op = AgentPlanOp::add,
                                           .plan_text = "First"}));
  check(progress.apply(ReportAgentProgress{.plan_op = AgentPlanOp::add,
                                           .plan_text = "Second"}));
  check(progress.apply(ReportAgentProgress{.plan_op = AgentPlanOp::mark,
                                           .plan_index = 1,
                                           .plan_status = AgentPlanStatus::in_progress}));
  check(progress.step() == "Second" && progress.total() == 2 && progress.done() == 0);
  progress.apply(ReportAgentProgress{.plan_op = AgentPlanOp::mark,
                                     .plan_index = 0,
                                     .plan_status = AgentPlanStatus::deleted});
  progress.apply(ReportAgentProgress{.final_message = "Finished",
                                     .plan_op = AgentPlanOp::mark,
                                     .plan_index = 1,
                                     .plan_status = AgentPlanStatus::completed});
  check(progress.total() == 1 && progress.done() == 1 && progress.step().empty());
  progress.apply(ReportAgentProgress{});
  check(progress.final_message.view() == "Finished");
  for (std::size_t index = 2; index < AgentProgress::task_capacity; ++index) {
    check(progress.apply(ReportAgentProgress{.plan_op = AgentPlanOp::add, .plan_text = "Another task"}));
  }
  check(!progress.apply(ReportAgentProgress{.final_message = "Preserved at capacity", .plan_op = AgentPlanOp::add, .plan_text = "Overflow"}));
  check(progress.final_message.view() == "Preserved at capacity");
  PromptBudget budget;
  const auto now = std::chrono::steady_clock::now();
  for (unsigned index = 0; index < 8; ++index) {
    check(budget.spend(1, 2, now));
  }
  check(!budget.spend(1, 2, now));
  check(budget.spend(1, 3, now));
  check(budget.spend(1, 2, now + std::chrono::seconds{60}));
}

static void testReporterCredentials(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-credentials-test.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientLayouts layouts{memory};
  TestProcessInspector inspector;
  AgentService<SystemAllocator, decltype(poller)> agents{memory};
  DescentService<SystemAllocator, decltype(inspector)> verification{inspector};
  ClientPeer reporter{memory, model, clients, ClientRole::control};
  ClientPeer other_client{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  std::array<std::uint64_t, 2> identities;
  for (auto &identity : identities) {
    workspaces.createWorkspace(model, panes, clients, reporter.session().id, CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    identity = reporter.receive<PaneOpened>().pane_id;
  }

  auto &pane = panes.require(model.panes, identities[0]);
  auto &other_pane = panes.require(model.panes, identities[1]);
  ReportAgent report{.request_id = 2, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude, .state = AgentReportState::working};
  const auto rejected = [&](auto &&action, FailureCode expected) {
    try {
      action();
    } catch (const RequestError &error) {
      return error.code() == expected;
    }

    return false;
  };
  check(rejected([&] { agents.report(model, reporter.session(), report); }, FailureCode::foreign_process));
  reporter.session().peer_identity = inspector.current;
  verifyAndWait(verification, model, clients, reporter, VerifyPaneDescent{3, pane.id, pane.generation});
  reporter.receive<RequestCompleted>();
  check(inspector.descent_checks == 1);

  inspector.descendant = false;
  for (unsigned index = 0; index < 3; ++index) {
    agents.report(model, reporter.session(), report);
    reporter.receive<RequestCompleted>();
  }
  check(inspector.descent_checks == 1);
  check(rejected([&] { agents.report(model, other_client.session(), report); }, FailureCode::foreign_process));

  auto wrong_generation = report;
  ++wrong_generation.pane_generation;
  check(rejected([&] { agents.report(model, reporter.session(), wrong_generation); }, FailureCode::pane_not_found));
  auto wrong_pane = report;
  wrong_pane.pane_id = other_pane.id;
  wrong_pane.pane_generation = other_pane.generation;
  check(rejected([&] { agents.report(model, reporter.session(), wrong_pane); }, FailureCode::foreign_process));
  auto wrong_provider = report;
  wrong_provider.provider = AgentProvider::codex;
  check(rejected([&] { agents.report(model, reporter.session(), wrong_provider); }, FailureCode::foreign_process));

  verifyAndWait(verification, model, clients, reporter, VerifyPaneDescent{4, other_pane.id, other_pane.generation});
  check(reporter.receive<RequestFailed>().code == FailureCode::foreign_process);
  check(reporter.session().verified_pane == 0 && reporter.session().verified_generation == 0);
  check(rejected([&] { agents.report(model, reporter.session(), report); }, FailureCode::foreign_process));
  report.provider = AgentProvider::unknown;
  agents.report(model, other_client.session(), report);
  other_client.receive<RequestCompleted>();
}

static void testEvidencePrecedence() {
  Agent codex{1, 1};
  codex.observeProcess(ProcessIdentity{41, 1, 1, 0}, AgentProvider::codex, {100, 100});
  check(codex.status == AgentStatus::unknown);
  codex.report(ReportAgent{.provider = AgentProvider::codex, .state = AgentReportState::working, .event = "Tool running"}, {200, 200});
  check(codex.status == AgentStatus::working);
  check(!codex.observeScreen({AgentProvider::codex, AgentStatus::ready, 94, true, true}, {200, 201}));
  check(codex.status == AgentStatus::working);

  codex.report(ReportAgent{.provider = AgentProvider::codex, .state = AgentReportState::settling}, {300, 300});
  check(!codex.observeScreen({AgentProvider::codex, AgentStatus::ready, 94, true, true}, {300, 299}));
  check(codex.observeScreen({AgentProvider::codex, AgentStatus::ready, 94, true, true}, {300, 301}));
  check(codex.status == AgentStatus::done && codex.source == AgentSource::screen);
  check(codex.confidence == 94 && codex.expires_at == 1'800'300);

  codex.report(ReportAgent{.state = AgentReportState::working}, {400, 400});
  check(!codex.evidence.screen);
  check(!codex.report(ReportAgent{.state = AgentReportState::continuing}, {401, 401}));
  const auto original_time = codex.observed_at;
  check(codex.report(ReportAgent{.state = AgentReportState::continuing}, {300'401, 300'401}));
  check(codex.observed_at == original_time && codex.expires_at == 900'401);
  check(codex.report(ReportAgent{.state = AgentReportState::exited}, {300'500, 300'500}));
  check(codex.status == AgentStatus::unknown && codex.source == AgentSource::foreground_process);

  Agent cursor{2, 1};
  cursor.observeProcess(ProcessIdentity{42, 1, 1, 0}, AgentProvider::cursor, {100, 100});
  cursor.report(ReportAgent{.provider = AgentProvider::cursor, .state = AgentReportState::working}, {200, 200});
  cursor.observeScreen({AgentProvider::unknown, AgentStatus::blocked, 88}, {300, 300});
  check(cursor.status == AgentStatus::blocked && cursor.authority == AgentAuthority::obscured);
  check(cursor.blocked_reason == AgentBlockedReason::other && cursor.event.view().empty());
  cursor.report(ReportAgent{.state = AgentReportState::ready}, {400, 400});
  check(cursor.status == AgentStatus::blocked);
  cursor.report(ReportAgent{.state = AgentReportState::working}, {500, 500});
  check(cursor.status == AgentStatus::working && cursor.authority == AgentAuthority::active);

  Agent claude{3, 1};
  claude.observeProcess(ProcessIdentity{43, 1, 1, 0}, AgentProvider::claude, {100, 100});
  claude.observeScreen({AgentProvider::claude, AgentStatus::working, 78}, {200, 200});
  check(!claude.observeScreen({AgentProvider::claude, AgentStatus::ready, 90, true, false}, {300, 300}));
  claude.report(ReportAgent{.provider = AgentProvider::claude, .state = AgentReportState::waiting}, {400, 400});
  check(!claude.report(ReportAgent{.state = AgentReportState::idle}, {500, 500}));
  check(claude.report(ReportAgent{.state = AgentReportState::released}, {600, 600}));
  check(claude.status == AgentStatus::done);
  claude.setSession("old-session");
  claude.progress.apply(ReportAgentProgress{.final_message = "Preserved"});
  claude.setSession("new-session");
  check(claude.progress.final_message.view() == "Preserved");
  claude.reportTitle("Previous agent title");
  claude.observeProcess(ProcessIdentity{44, 1, 2, 0}, AgentProvider::codex, {700, 700});
  check(claude.session.view().empty() && claude.progress.final_message.view().empty());
  check(claude.status == AgentStatus::unknown);
  check(claude.title.view().empty());
  check(claude.description_phase == DescriptionPhase::waiting_query);
}

static void testDescriptionQueue(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/tmp/unused-description-test.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientLayouts layouts{memory};
  AgentService<SystemAllocator, decltype(poller)> agents{memory};
  agents.enableDescriptions(true);
  ClientPeer reporter{memory, model, clients, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const std::string_view prompt = "Fix parser\r";
  std::array<std::uint64_t, 9> identities;
  for (auto &identity : identities) {
    workspaces.createWorkspace(model, panes, clients, reporter.session().id, CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    identity = reporter.receive<PaneOpened>().pane_id;
    auto &pane = panes.require(model.panes, identity);
    agents.report(model, reporter.session(), ReportAgent{.request_id = 1, .pane_id = pane.id, .pane_generation = pane.generation, .state = AgentReportState::ready});
    reporter.receive<RequestCompleted>();
    agents.observeInput(pane, {reinterpret_cast<const Byte *>(prompt.data()), prompt.size()});
    check(agents.find(pane.id, pane.generation)->description_phase == DescriptionPhase::waiting_work);
    agents.report(model, reporter.session(), ReportAgent{.request_id = 1, .pane_id = pane.id, .pane_generation = pane.generation, .state = AgentReportState::working});
    reporter.receive<RequestCompleted>();
  }

  check(agents.find(identities.front(), panes.require(model.panes, identities.front()).generation)->title_state == AgentTitleState::pending);
  check(agents.find(identities.back(), panes.require(model.panes, identities.back()).generation)->description_phase == DescriptionPhase::waiting_work);
  auto request = agents.nextDescription();
  check(request && request->query.view() == "Fix parser");
  check(!agents.nextDescription());
  DescriptionResult result{.identity = request->identity, .status = DescriptionStatus::success};
  result.title.assign("Generated title");
  ++result.identity.generation;
  check(!agents.completeDescription(result));
  result.identity = request->identity;
  ++result.identity.revision;
  check(!agents.completeDescription(result));
  result.identity = request->identity;
  result.identity.session[0] ^= 1;
  check(!agents.completeDescription(result));
  result.identity = request->identity;
  const auto title = agents.completeDescription(result);
  check(title && title->title.view() == "Generated title");
  check(!agents.completeDescription(result));
  check(agents.find(request->identity.pane, request->identity.generation)->title_source == AgentTitleSource::generated);

  request = agents.nextDescription();
  check(request.has_value());
  check(agents.find(identities.back(), panes.require(model.panes, identities.back()).generation)->title_state == AgentTitleState::pending);
  agents.reportTitle(model, reporter.session(), ReportAgentTitle{.request_id = 1, .pane_id = request->identity.pane, .pane_generation = request->identity.generation, .title = "Agent title"});
  reporter.receive<RequestCompleted>();
  result.identity = request->identity;
  check(!agents.completeDescription(result));
  check(agents.find(request->identity.pane, request->identity.generation)->title.view() == "Agent title");
  agents.reportTitle(model, reporter.session(), ReportAgentTitle{.request_id = 1, .pane_id = request->identity.pane, .pane_generation = request->identity.generation, .title = {}});
  reporter.receive<RequestCompleted>();
  check(agents.find(request->identity.pane, request->identity.generation)->description_phase == DescriptionPhase::finished);

  request = agents.nextDescription();
  check(request.has_value());
  result.identity = request->identity;
  result.status = DescriptionStatus::timeout;
  const auto failed = agents.completeDescription(result);
  check(failed && failed->state == AgentTitleState::failed && failed->title.view().empty());
}

void testAgents() {
  SystemAllocator memory;
  testScreenEvidence(memory);
  testReportsAndIdentity(memory);
  testReporterCredentials(memory);
  testProgressAndPromptBudget();
  testEvidencePrecedence();
  testDescriptionQueue(memory);
}
