#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "client_peer.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <span>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <sys/types.h>
#include <bit>
#include <concepts>
#include "telar_client/serializers/telar_messages.hpp"
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include <unistd.h>
#include <tuple>
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#include <sys/stat.h>
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
#include <termios.h>
#include <condition_variable>
#include <pthread.h>
#include <thread>



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
static void verifyAndWait(Verification &verification, ClientPeer &reporter, const VerifyPaneDescent &request) {
  verification.verify(reporter.session(), request);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while (reporter.session().pending_descent) {
    verification.collect();
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
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/unused-agent-test.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientLayouts layouts{memory, model};
  TestProcessInspector inspector;
  AgentService agents{memory, model, panes, layouts};
  DescentService verification{model, inspector};
  ClientPeer reporter{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(reporter.session(), OpenPane{.request_id = 1,
                                               .size = {80, 24, 8, 16},
                                               .launch = Launch{.cwd = "/tmp",
                                                                .arguments = arguments}});
  const auto opened = reporter.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  reporter.session().peer_identity = inspector.current;
  inspector.descendant = false;
  verifyAndWait(verification, reporter, VerifyPaneDescent{2, pane.id, pane.generation});
  check(reporter.receive<RequestFailed>().code == FailureCode::foreign_process);
  inspector.descendant = true;
  verifyAndWait(verification, reporter, VerifyPaneDescent{2, pane.id, pane.generation});
  check(reporter.receive<RequestCompleted>().request_id == 2);
  agents.report(reporter.session(), ReportAgent{.request_id = 3,
                                                .pane_id = pane.id,
                                                .pane_generation = pane.generation,
                                                .provider = AgentProvider::claude,
                                                .state = AgentReportState::working,
                                                .session = "session-one"});
  reporter.receive<RequestCompleted>();
  const auto now = std::chrono::steady_clock::now();
  agents.observeProcess(pane, inspector.current, inspector.active);
  agents.refresh(now);
  agents.query(reporter.session());
  auto snapshot = reporter.receive<AgentSnapshot>();
  check(snapshot.entries.size() == 1 && snapshot.entries[0].status == AgentStatus::working);
  ReportAgent file_report{.request_id = 30, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude, .state = AgentReportState::working, .session = "session-one", .session_file = "/tmp/first-transcript"};
  agents.report(reporter.session(), file_report);
  reporter.receive<RequestCompleted>();
  const auto first_probe = agents.nextSessionFile(now);
  check(first_probe.has_value());
  file_report.session_file = "/tmp/second-transcript";
  agents.report(reporter.session(), file_report);
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
  agents.reportTitle(reporter.session(), ReportAgentTitle{.request_id = 31, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude});
  reporter.receive<RequestCompleted>();

  const std::vector<Byte> blocked_input(Pane<SystemAllocator>::input_limit, 'a');
  pane.input.append(blocked_input);
  const auto input_revision = pane.input_revision;
  agents.interrupt(reporter.session(), InterruptAgent{4, pane.id, pane.generation});
  check(reporter.receive<RequestCompleted>().request_id == 4);
  check(pane.input.size() == blocked_input.size() && pane.input_revision == input_revision);
  check(model.limits.runtime.rows().size() == 1 && model.limits.runtime.rows().front().reach().name == "panes.input_queue_capacity");
#if TELAR_DIAGNOSTICS
  check(pane.input_dropped_bytes > 0);
#endif
  pane.input.clear();
  feedAgent(pane.terminal, "\x1b]0;◐ Working\x1b\\\x1b[22;1H❯ ");
  agents.refresh(now + std::chrono::seconds{4});
  agents.query(reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::working);
  feedAgent(pane.terminal, "\x1b]0;✳ Idle\x1b\\");
  agents.refresh(now + std::chrono::seconds{5});
  agents.refresh(now + std::chrono::milliseconds{5600});
  agents.query(reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::done);
  agents.acknowledge(AcknowledgeAgent{pane.id, pane.generation});
  agents.query(reporter.session());
  check(reporter.receive<AgentSnapshot>().entries[0].status == AgentStatus::ready);
  inspector.active = AgentProvider::codex;
  ++inspector.current.started_seconds;
  agents.observeProcess(pane, inspector.current, inspector.active);
  agents.refresh(now + std::chrono::seconds{7});
  agents.query(reporter.session());
  snapshot = reporter.receive<AgentSnapshot>();
  check(snapshot.entries[0].provider == AgentProvider::codex && snapshot.entries[0].status == AgentStatus::unknown);
  check(snapshot.entries[0].confidence == 100 && snapshot.entries[0].expires_at_ms == INT64_MAX);
  agents.observeProcess(pane, inspector.current, AgentProvider::unknown);
  agents.query(reporter.session());
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
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/unused-credentials-test.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientLayouts layouts{memory, model};
  TestProcessInspector inspector;
  AgentService agents{memory, model, panes, layouts};
  DescentService verification{model, inspector};
  ClientPeer reporter{memory, model, ClientRole::control};
  ClientPeer other_client{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  std::array<std::uint64_t, 2> identities;
  for (auto &identity : identities) {
    workspaces.createWorkspace(reporter.session(), CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    identity = reporter.receive<PaneOpened>().pane_id;
  }

  auto &pane = panes.require(identities[0]);
  auto &other_pane = panes.require(identities[1]);
  ReportAgent report{.request_id = 2, .pane_id = pane.id, .pane_generation = pane.generation, .provider = AgentProvider::claude, .state = AgentReportState::working};
  const auto rejected = [&](auto &&action, FailureCode expected) {
    try {
      action();
    } catch (const RequestError &error) {
      return error.code() == expected;
    }

    return false;
  };
  check(rejected([&] { agents.report(reporter.session(), report); }, FailureCode::foreign_process));
  reporter.session().peer_identity = inspector.current;
  verifyAndWait(verification, reporter, VerifyPaneDescent{3, pane.id, pane.generation});
  reporter.receive<RequestCompleted>();
  check(inspector.descent_checks == 1);

  inspector.descendant = false;
  for (unsigned index = 0; index < 3; ++index) {
    agents.report(reporter.session(), report);
    reporter.receive<RequestCompleted>();
  }
  check(inspector.descent_checks == 1);
  check(rejected([&] { agents.report(other_client.session(), report); }, FailureCode::foreign_process));

  auto wrong_generation = report;
  ++wrong_generation.pane_generation;
  check(rejected([&] { agents.report(reporter.session(), wrong_generation); }, FailureCode::pane_not_found));
  auto wrong_pane = report;
  wrong_pane.pane_id = other_pane.id;
  wrong_pane.pane_generation = other_pane.generation;
  check(rejected([&] { agents.report(reporter.session(), wrong_pane); }, FailureCode::foreign_process));
  auto wrong_provider = report;
  wrong_provider.provider = AgentProvider::codex;
  check(rejected([&] { agents.report(reporter.session(), wrong_provider); }, FailureCode::foreign_process));

  verifyAndWait(verification, reporter, VerifyPaneDescent{4, other_pane.id, other_pane.generation});
  check(reporter.receive<RequestFailed>().code == FailureCode::foreign_process);
  check(reporter.session().verified_pane == 0 && reporter.session().verified_generation == 0);
  check(rejected([&] { agents.report(reporter.session(), report); }, FailureCode::foreign_process));
  report.provider = AgentProvider::unknown;
  agents.report(other_client.session(), report);
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
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/unused-description-test.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientLayouts layouts{memory, model};
  AgentService agents{memory, model, panes, layouts};
  agents.enableDescriptions(true);
  ClientPeer reporter{memory, model, ClientRole::control};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const std::string_view prompt = "Fix parser\r";
  std::array<std::uint64_t, 9> identities;
  for (auto &identity : identities) {
    workspaces.createWorkspace(reporter.session(), CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    identity = reporter.receive<PaneOpened>().pane_id;
    auto &pane = panes.require(identity);
    agents.report(reporter.session(), ReportAgent{.request_id = 1, .pane_id = pane.id, .pane_generation = pane.generation, .state = AgentReportState::ready});
    reporter.receive<RequestCompleted>();
    agents.observeInput(pane, {reinterpret_cast<const Byte *>(prompt.data()), prompt.size()});
    check(agents.find(pane.id, pane.generation)->description_phase == DescriptionPhase::waiting_work);
    agents.report(reporter.session(), ReportAgent{.request_id = 1, .pane_id = pane.id, .pane_generation = pane.generation, .state = AgentReportState::working});
    reporter.receive<RequestCompleted>();
  }

  check(agents.find(identities.front(), panes.require(identities.front()).generation)->title_state == AgentTitleState::pending);
  check(agents.find(identities.back(), panes.require(identities.back()).generation)->description_phase == DescriptionPhase::waiting_work);
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
  check(agents.find(identities.back(), panes.require(identities.back()).generation)->title_state == AgentTitleState::pending);
  agents.reportTitle(reporter.session(), ReportAgentTitle{.request_id = 1, .pane_id = request->identity.pane, .pane_generation = request->identity.generation, .title = "Agent title"});
  reporter.receive<RequestCompleted>();
  result.identity = request->identity;
  check(!agents.completeDescription(result));
  check(agents.find(request->identity.pane, request->identity.generation)->title.view() == "Agent title");
  agents.reportTitle(reporter.session(), ReportAgentTitle{.request_id = 1, .pane_id = request->identity.pane, .pane_generation = request->identity.generation, .title = {}});
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
