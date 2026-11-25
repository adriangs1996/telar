import std;
import telar.testing;
import telar.config.runtime;
import telar.runtime.agents.snapshot;
import telar.runtime.host.process_probe;
import telar.platform.events;
import telar.wire.agents;
import telar.wire.vocabulary;

// How the evidence of one agent, its hooks, its screen and its process, becomes the status it shows.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::int64_t settle = AgentEvidenceState::ready_settle.count();

  ObservationTime at(std::int64_t milliseconds) {
    return {.milliseconds = milliseconds, .nanoseconds = milliseconds * 1'000'000};
  }

  Agent running(AgentProvider provider) {
    Agent agent{{.id = 1, .generation = 1}};

    agent.observeProcess(ProcessIdentity{41, 1, 1, 0}, provider, at(100));
    return agent;
  }

  void report(Agent& agent, AgentReportState state, std::int64_t time, AgentBlockedReason reason = AgentBlockedReason::none) {
    agent.report(ReportAgent{.state = state, .blocked_reason = reason}, at(time));
  }

  void screen(Agent& agent, AgentStatus status, std::int64_t time) {
    agent.observeScreen(AgentSignal{.provider = agent.evidence.provider(), .status = status, .confidence = 94, .identity_confirmed = true, .ready_confirmed = status == AgentStatus::ready}, at(time));
  }

  // Esc ends a Claude turn with no hook: the idle prompt ends it, as a stop and not a result.
  void claudeEscape() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 200);
    screen(agent, AgentStatus::working, 300);
    screen(agent, AgentStatus::ready, 1'000);
    check(agent.status == AgentStatus::working, "a frame of Claude's idle prompt ends its turn");
    agent.project(1'000 + settle);
    check(agent.status == AgentStatus::ready, "the idle prompt after Esc leaves Claude working");

    // A Stop that comes after the prompt shows says the turn finished: its result is unseen.
    report(agent, AgentReportState::ready, 1'000 + settle + 100);
    check(agent.status == AgentStatus::done, "a Stop after the idle prompt loses the turn's result");

    // A new prompt is work again, though the idle prompt still shows from before it.
    report(agent, AgentReportState::working, 5'000);
    agent.project(5'000 + settle);
    check(agent.status == AgentStatus::working, "an idle prompt from before a turn ends it");
  }

  // A permission dialog blocks Claude when it shows, and the work after the answer runs as work.
  void claudePermission() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 200);
    screen(agent, AgentStatus::blocked, 300);
    check(agent.status == AgentStatus::blocked, "Claude's permission dialog waits for its notification to block it");
    report(agent, AgentReportState::blocked, 6'300, AgentBlockedReason::permission);
    check(agent.status == AgentStatus::blocked && agent.blocked_reason == AgentBlockedReason::permission);

    // Approved: the tool runs, and only its PostToolUse would say so.
    screen(agent, AgentStatus::working, 7'000);
    check(agent.status == AgentStatus::working, "an approved tool runs as blocked");
  }

  // A denied permission ends the turn at the idle prompt with no hook.
  void claudeDenied() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 150);
    report(agent, AgentReportState::blocked, 200, AgentBlockedReason::permission);
    screen(agent, AgentStatus::ready, 300);
    agent.project(300 + settle);
    check(agent.status == AgentStatus::ready, "a denied permission leaves Claude blocked");
  }

  // A tool that finishes beside one that waits for permission does not unblock the session.
  void claudeParallelTools() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 200);
    screen(agent, AgentStatus::blocked, 300);
    report(agent, AgentReportState::working, 400);
    check(agent.status == AgentStatus::blocked, "another tool's PostToolUse hides the dialog on screen");
    screen(agent, AgentStatus::unknown, 500);
    check(agent.status == AgentStatus::working, "a dialog no longer on screen still blocks Claude");
  }

  // A turn that waits on background work shows the idle prompt and keeps working.
  void claudeWaits() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 200);
    report(agent, AgentReportState::waiting, 300);
    screen(agent, AgentStatus::ready, 400);
    agent.project(400 + (settle * 4));
    check(agent.status == AgentStatus::working, "the idle prompt ends a turn that waits on background work");
  }

  // A dialog Claude shows between turns, as a picker the user opened, leaves its result unseen.
  void claudeDialogAfterTurn() {
    auto agent = running(AgentProvider::claude);

    report(agent, AgentReportState::working, 200);
    report(agent, AgentReportState::ready, 300);
    check(agent.status == AgentStatus::done);
    screen(agent, AgentStatus::blocked, 400);
    check(agent.status == AgentStatus::done, "a dialog between turns replaces Claude's Stop");
  }

  // An API error ends the turn as failed, and the next turn works again.
  void failedTurns() {
    for (const auto provider : {AgentProvider::claude, AgentProvider::cursor}) {
      auto agent = running(provider);

      report(agent, AgentReportState::working, 200);
      report(agent, AgentReportState::failed, 300);
      check(agent.status == AgentStatus::failed, "a failed turn reads as finished");
      report(agent, AgentReportState::working, 400);
      check(agent.status == AgentStatus::working);
    }
  }

  // A stopped turn is idle with no result to read.
  void interruptedTurns() {
    for (const auto provider : {AgentProvider::codex, AgentProvider::cursor}) {
      auto agent = running(provider);

      report(agent, AgentReportState::working, 200);
      report(agent, AgentReportState::interrupted, 300);
      check(agent.status == AgentStatus::ready, "an interrupted turn reads as done");
    }
  }

  // Codex's Stop settles on its idle composer; with no composer, it settles when its report ends.
  void codexSettles() {
    auto agent = running(AgentProvider::codex);

    report(agent, AgentReportState::working, 200);
    report(agent, AgentReportState::settling, 300);
    agent.project(300 + AgentEvidence::screen_working_expiry.count() - 1);
    check(agent.status == AgentStatus::working);

    const auto ended = 300 + AgentEvidence::screen_working_expiry.count() + 1;

    agent.evidence.expire(ended);
    agent.project(ended);
    check(agent.status == AgentStatus::done, "a Codex turn no screen settled ends unknown");
  }

  // Codex's approval on screen blocks it, and the approved command runs as work.
  void codexApproval() {
    auto agent = running(AgentProvider::codex);

    report(agent, AgentReportState::working, 200);
    screen(agent, AgentStatus::blocked, 300);
    check(agent.status == AgentStatus::blocked, "Codex's approval on screen does not block it");
    report(agent, AgentReportState::blocked, 350, AgentBlockedReason::permission);
    screen(agent, AgentStatus::working, 400);
    check(agent.status == AgentStatus::working, "an approved Codex command runs as blocked");
  }

  // An idle agent stays idle, and its unseen result stays unseen, after its evidence expires.
  void settledOutlivesEvidence() {
    for (const auto provider : {AgentProvider::pi, AgentProvider::opencode, AgentProvider::cursor}) {
      auto agent = running(provider);

      report(agent, AgentReportState::working, 200);
      report(agent, AgentReportState::ready, 300);
      check(agent.status == AgentStatus::done);

      const auto later = 300 + AgentEvidence::settled_expiry.count() + 1;

      agent.evidence.expire(later);
      agent.project(later);
      check(agent.status == AgentStatus::done, "an idle agent reads as unknown once its report expires");
    }
  }

  // A question that shows between a result and its reading does not mark the result read.
  void doneSurvivesQuestion() {
    auto agent = running(AgentProvider::claude);

    screen(agent, AgentStatus::working, 200);
    screen(agent, AgentStatus::ready, 300);
    check(agent.status == AgentStatus::done);
    screen(agent, AgentStatus::blocked, 400);
    check(agent.status == AgentStatus::blocked);
    screen(agent, AgentStatus::ready, 500);
    check(agent.status == AgentStatus::done, "a question in between marks the result read");
  }

  // The working phrases of an agent no reader knows end its work when they are gone a while.
  void lostWorkingPhrases() {
    auto agent = running(static_cast<AgentProvider>(first_custom_agent_provider));

    screen(agent, AgentStatus::working, 200);
    screen(agent, AgentStatus::unknown, 300);
    agent.project(300 + AgentEvidenceState::lost_working.count() - 1);
    check(agent.status == AgentStatus::working, "a frame without the phrases ends the work");
    agent.project(300 + AgentEvidenceState::lost_working.count());
    check(agent.status == AgentStatus::done, "working phrases that are gone keep the agent working");
  }

  // A screen the observer still reads as it was keeps its evidence past its expiry.
  void currentScreenHolds() {
    auto agent = running(AgentProvider::claude);

    screen(agent, AgentStatus::working, 200);

    const auto later = 200 + AgentEvidence::screen_working_expiry.count() + 1;

    agent.evidence.expire(later);
    agent.project(later);
    check(agent.status == AgentStatus::working, "a screen that still shows work stops counting");
  }

  // A question on screen obscures what the agent says until the screen shows something else.
  void authorityRecovers() {
    auto agent = running(AgentProvider::cursor);

    screen(agent, AgentStatus::blocked, 200);
    check(agent.authority == AgentAuthority::obscured);
    screen(agent, AgentStatus::ready, 300);
    check(agent.authority == AgentAuthority::active, "an answered question keeps the agent obscured");
  }

  const telar::testing::Case case_claude_escape{"evidence.claude_escape", claudeEscape};
  const telar::testing::Case case_claude_permission{"evidence.claude_permission", claudePermission};
  const telar::testing::Case case_claude_denied{"evidence.claude_denied", claudeDenied};
  const telar::testing::Case case_claude_parallel_tools{"evidence.claude_parallel_tools", claudeParallelTools};
  const telar::testing::Case case_claude_waits{"evidence.claude_waits", claudeWaits};
  const telar::testing::Case case_claude_dialog_after_turn{"evidence.claude_dialog_after_turn", claudeDialogAfterTurn};
  const telar::testing::Case case_failed_turns{"evidence.failed_turns", failedTurns};
  const telar::testing::Case case_interrupted_turns{"evidence.interrupted_turns", interruptedTurns};
  const telar::testing::Case case_codex_settles{"evidence.codex_settles", codexSettles};
  const telar::testing::Case case_codex_approval{"evidence.codex_approval", codexApproval};
  const telar::testing::Case case_settled_outlives_evidence{"evidence.settled_outlives_evidence", settledOutlivesEvidence};
  const telar::testing::Case case_done_survives_question{"evidence.done_survives_question", doneSurvivesQuestion};
  const telar::testing::Case case_lost_working_phrases{"evidence.lost_working_phrases", lostWorkingPhrases};
  const telar::testing::Case case_current_screen_holds{"evidence.current_screen_holds", currentScreenHolds};
  const telar::testing::Case case_authority_recovers{"evidence.authority_recovers", authorityRecovers};

}
