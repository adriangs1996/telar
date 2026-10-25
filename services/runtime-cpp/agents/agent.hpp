#pragma once

#include "../platform/process_inspector.hpp"
#include "description.hpp"
#include "evidence_state.hpp"
#include "progress.hpp"
#include "session_file.hpp"

namespace telar::runtime {

struct Agent {
  Agent(std::uint64_t pane, std::uint64_t generation)
      : pane(pane),
        generation(generation) {}

  void setSession(std::string_view value) {
    if (!value.empty()) {
      session.assign(value);
    }
  }

  bool report(const ReportAgent &incoming, ObservationTime now = ObservationTime::now()) {
    if (!evidence.accepts(incoming.provider)) {
      return false;
    }

    evidence.claim(incoming.provider);
    if (incoming.state != AgentReportState::continuing) {
      setSession(incoming.session);
      if (!incoming.session_file.empty()) {
        file_watch.configure(session.view(), incoming.session_file, incoming.session_file_kind);
      }
    }

    if (!evidence.applyReport(incoming, now)) {
      return false;
    }

    if (incoming.state != AgentReportState::continuing && incoming.state != AgentReportState::exited) {
      interrupt_at.reset();
      interrupt_idle_at.reset();
      interrupt_draft_cleared = false;
    }

    return project(now.milliseconds);
  }

  bool observeProcess(ProcessIdentity identity, AgentProvider incoming, ObservationTime now = ObservationTime::now()) {
    if (process_identity == identity && evidence.process && evidence.process->provider == incoming) {
      return false;
    }

    const bool replacing = evidence.process.has_value();
    if ((!replacing && evidence.reporter != AgentProvider::unknown && evidence.reporter != incoming) || (replacing && evidence.process->provider != incoming)) {
      forgetReports();
    }

    if (replacing) {
      evidence.screen.reset();
      evidence.report.reset();
      evidence.work.reset();
      evidence.hooks_seen = false;
      unreported_work_at.reset();
    }

    evidence.reporter = AgentProvider::unknown;
    evidence.process = AgentEvidence::process(incoming, now);
    process_identity = identity;
    if (replacing || evidence.authority == AgentAuthority::candidate || evidence.authority == AgentAuthority::stale || evidence.authority == AgentAuthority::exited) {
      evidence.authority = AgentAuthority::active;
    }

    return project(now.milliseconds);
  }

  bool observeScreen(AgentSignal signal, ObservationTime now = ObservationTime::now()) {
    if (!evidence.applyScreen(signal, now, status, interrupt_at.has_value())) {
      return false;
    }

    if (!evidence.report) {
      interrupt_at.reset();
      interrupt_idle_at.reset();
    }

    if (signal.status != AgentStatus::working) {
      unreported_work_at.reset();
    } else if (!evidence.hooks_seen && !unreported_work_at) {
      unreported_work_at = now.milliseconds;
    }

    return project(now.milliseconds);
  }

  bool setProcessContext(SessionHost host, bool installed, std::optional<ProcessIdentity> identity) noexcept {
    const bool changed = session_host != host || hooks_installed != installed;
    session_host = host;
    in_pane = host == SessionHost::pane;
    hooks_installed = installed;
    agent_identity = identity;
    return changed;
  }

  std::string_view eventFor(const AgentEvidence &selected, std::int64_t now) const noexcept {
    if (selected.source == AgentSource::lifecycle_report) {
      return evidence.report_event.view();
    }

    constexpr std::int64_t missing_hooks_grace_ms = 5'000;
    if (session_host == SessionHost::shared_server && hooks_installed && !evidence.hooks_seen && unreported_work_at && now - *unreported_work_at >= missing_hooks_grace_ms) {
      return "no hooks from this pane: if it runs on a shared server, start it with --no-daemon";
    }

    return {};
  }

  bool project(std::int64_t now) {
    const auto selected = evidence.choose(now);
    if (!selected) {
      return false;
    }

    auto next_status = selected->status;
    if (next_status != AgentStatus::ready) {
      acknowledged = true;
    } else {
      if (status == AgentStatus::working) {
        acknowledged = false;
      }

      next_status = acknowledged ? AgentStatus::ready : AgentStatus::done;
    }

    const auto next_provider = evidence.process ? evidence.process->provider : selected->provider != AgentProvider::unknown ? selected->provider
                                                                           : evidence.screen                                ? evidence.screen->provider
                                                                                                                            : AgentProvider::unknown;
    const auto next_reason = next_status == AgentStatus::blocked ? (selected->source == AgentSource::lifecycle_report && evidence.report_reason != AgentBlockedReason::none ? evidence.report_reason : AgentBlockedReason::other) : AgentBlockedReason::none;
    const auto next_event = eventFor(*selected, now);
    const bool changed = provider != next_provider || status != next_status || source != selected->source || authority != evidence.authority || confidence != selected->confidence || observed_at != selected->observed.milliseconds || expires_at != selected->expires_at || blocked_reason != next_reason || event.view() != next_event || projected_process != process_identity;
    if (status != next_status || changed_at == 0) {
      changed_at = now;
    }

    provider = next_provider;
    status = next_status;
    source = selected->source;
    authority = evidence.authority;
    confidence = selected->confidence;
    observed_at = selected->observed.milliseconds;
    expires_at = selected->expires_at;
    blocked_reason = next_reason;
    event.assign(next_event);
    projected_process = process_identity;
    return changed;
  }

  void forgetReports() {
    evidence.clearReport();
    evidence.work.reset();
    evidence.hooks_seen = false;
    unreported_work_at.reset();
    session.assign({});
    file_watch.clear();
    worktree = 0;
    progress = {};
    if (title_source == AgentTitleSource::agent) {
      title.assign({});
      title_source = AgentTitleSource::telar;
      title_state = AgentTitleState::placeholder;
      description_capture.clear();
      description_phase = DescriptionPhase::waiting_query;
    }
  }

  bool reportTitle(std::string_view value) {
    if (value.empty()) {
      if (title_source != AgentTitleSource::agent) {
        return false;
      }

      title.assign({});
      title_source = AgentTitleSource::telar;
      title_state = AgentTitleState::placeholder;
      finishTitleCapture();
      return true;
    }

    validateUtf8(value);
    if (value.size() > 96 || std::ranges::any_of(value, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
      throw EncodingError{"Invalid agent session title"};
    }
    if (title_source == AgentTitleSource::agent && title.view() == value) {
      return false;
    }

    title.assign(value);
    title_source = AgentTitleSource::agent;
    title_state = AgentTitleState::ready;
    finishTitleCapture();
    return true;
  }

  void observeInput(std::span<const Byte> bytes) {
    if (description_phase == DescriptionPhase::waiting_query && description_capture.feed(bytes)) {
      description_phase = DescriptionPhase::waiting_work;
    }
  }

  bool queueDescription() noexcept {
    if (description_phase != DescriptionPhase::waiting_work || status != AgentStatus::working) {
      return false;
    }

    description_phase = DescriptionPhase::queued;
    title_state = AgentTitleState::pending;
    return true;
  }

  void finishTitleCapture() noexcept {
    description_phase = DescriptionPhase::finished;
    description_capture.clear();
  }

  bool hasPendingDescription() const noexcept {
    return description_phase == DescriptionPhase::queued || description_phase == DescriptionPhase::running;
  }

  std::uint64_t pane;
  std::uint64_t generation;
  AgentEvidenceState evidence;
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  AgentBlockedReason blocked_reason = AgentBlockedReason::none;
  AgentSource source = AgentSource::screen;
  AgentAuthority authority = AgentAuthority::candidate;
  Byte confidence = 0;
  AgentTitleSource title_source = AgentTitleSource::telar;
  AgentTitleState title_state = AgentTitleState::placeholder;
  std::array<Byte, 16> session_id{};
  FixedText<64> session;
  SessionFileWatch file_watch;
  FixedText<96> event;
  FixedText<96> title;
  DescriptionCapture description_capture;
  DescriptionPhase description_phase = DescriptionPhase::waiting_query;
  std::uint64_t description_revision = 0;
  AgentProgress progress;
  std::uint64_t worktree = 0;
  std::uint64_t sequence = 1;
  std::uint64_t cwd_revision = 0;
  std::uint64_t title_revision = 0;
  std::int64_t observed_at = 0;
  std::int64_t changed_at = 0;
  std::int64_t expires_at = 0;
  bool acknowledged = true;
  bool in_pane = false;
  std::optional<ProcessIdentity> process_identity;
  std::optional<ProcessIdentity> projected_process;
  std::optional<ProcessIdentity> agent_identity;
  SessionHost session_host = SessionHost::unknown;
  bool hooks_installed = false;
  std::optional<std::int64_t> unreported_work_at;
  std::uint64_t interrupt_revision = 0;
  bool interrupt_draft_cleared = false;
  std::optional<std::chrono::steady_clock::time_point> interrupt_at;
  std::optional<std::chrono::steady_clock::time_point> interrupt_idle_at;
};

}
