#pragma once

#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/agents/evidence.hpp"

namespace telar::runtime {

class AgentEvidenceState {
public:
  AgentProvider provider() const noexcept {
    return process ? process->provider : screen ? screen->provider
                                                : AgentProvider::unknown;
  }

  bool accepts(AgentProvider incoming) const noexcept {
    const auto running = process ? process->provider : reporter;
    return incoming == AgentProvider::unknown || running == AgentProvider::unknown || running == incoming;
  }

  void claim(AgentProvider incoming) noexcept {
    if (!process && incoming != AgentProvider::unknown) {
      reporter = incoming;
    }
  }

  bool applyReport(const ReportAgent &incoming, ObservationTime now) {
    if (incoming.provider != AgentProvider::unknown) {
      hooks_seen = true;
    }

    if (report && now.before(report->observed)) {
      return false;
    }

    if (incoming.state == AgentReportState::continuing) {
      if (!report || report->status != AgentStatus::working || report_state == AgentReportState::settling || report->expired(now.milliseconds) || report->expires_at - now.milliseconds > AgentEvidence::renewal_margin.count()) {
        return false;
      }

      report->expires_at = now.milliseconds + AgentEvidence::report_working_expiry.count();
      return true;
    }

    const bool waiting = report && report_state == AgentReportState::waiting && !report->expired(now.milliseconds);
    if ((incoming.state == AgentReportState::idle && waiting) || (incoming.state == AgentReportState::released && !waiting)) {
      return false;
    }

    if (incoming.state == AgentReportState::exited) {
      const bool changed = report.has_value();
      clearReport();
      work.reset();
      return changed;
    }

    if (provider() == AgentProvider::codex && (incoming.state == AgentReportState::working || incoming.state == AgentReportState::waiting) && screen && screen->status == AgentStatus::ready) {
      screen.reset();
    }

    report_state = incoming.state;
    report_reason = incoming.blocked_reason;
    report_event.assign(incoming.event);
    report = AgentEvidence::report(provider() == AgentProvider::unknown ? incoming.provider : provider(), incoming.state, now);
    if (incoming.state == AgentReportState::working || incoming.state == AgentReportState::waiting) {
      work = report;
    }

    if (authority != AgentAuthority::resumed) {
      authority = AgentAuthority::active;
    }

    return true;
  }

  bool applyScreen(AgentSignal signal, ObservationTime now, AgentStatus projected, bool interrupted) noexcept {
    const auto process_provider = process ? process->provider : AgentProvider::unknown;
    if (process_provider != AgentProvider::unknown && signal.provider != AgentProvider::unknown && signal.provider != process_provider) {
      return false;
    }

    const auto known = process_provider != AgentProvider::unknown ? process_provider : signal.provider != AgentProvider::unknown ? signal.provider
                                                                                                                                 : provider();
    if (known == AgentProvider::unknown || (signal.status == AgentStatus::ready && !signal.identity_confirmed && provider() != signal.provider)) {
      return false;
    }

    if (signal.status == AgentStatus::ready && projected == AgentStatus::working && !signal.ready_confirmed) {
      return false;
    }

    if (known == AgentProvider::codex) {
      if (screen && now.before(screen->observed)) {
        return false;
      }

      if (report) {
        if (!report->observed.before(now)) {
          return false;
        }

        if (signal.status == AgentStatus::ready) {
          if (!signal.ready_confirmed || (report->status == AgentStatus::working && report_state != AgentReportState::settling && !report->expired(now.milliseconds))) {
            return false;
          }

          if (!interrupted) {
            report.reset();
          }
        } else if (report->status == AgentStatus::ready) {
          report.reset();
        }
      }
    }

    screen = AgentEvidence::screen(known, signal, now);
    if (signal.status == AgentStatus::blocked) {
      authority = AgentAuthority::obscured;
    }

    return true;
  }

  std::optional<AgentEvidence> choose(std::int64_t now) const noexcept {
    const auto shown = screen && !screen->expired(now) ? screen : std::nullopt;
    if (report && !report->expired(now)) {
      const auto since = work ? work->observed : report->observed;
      if (shown && shown->status == AgentStatus::blocked && provider() == AgentProvider::cursor && since.before(shown->observed)) {
        return shown;
      }

      return report;
    }

    if (shown) {
      return shown;
    }

    auto presence = process;
    if (presence && completionRequiresSignal(presence->provider)) {
      presence->status = AgentStatus::unknown;
    }

    return presence;
  }

  void expire(std::int64_t now) noexcept {
    if (screen && screen->expired(now)) {
      screen.reset();
    }

    if (report && report->expired(now)) {
      report.reset();
    }
  }

  void clearReport() noexcept {
    report.reset();
    report_state = AgentReportState::ready;
    report_reason = AgentBlockedReason::none;
    report_event.assign({});
  }

  std::optional<AgentEvidence> process;
  std::optional<AgentEvidence> screen;
  std::optional<AgentEvidence> report;
  std::optional<AgentEvidence> work;
  AgentProvider reporter = AgentProvider::unknown;
  AgentAuthority authority = AgentAuthority::candidate;
  AgentReportState report_state = AgentReportState::ready;
  AgentBlockedReason report_reason = AgentBlockedReason::none;
  FixedText<96> report_event;
  bool hooks_seen = false;
};

}
