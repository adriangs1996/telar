#pragma once

#include "../diagnostics/limit_ledger.hpp"
#include "../platform/observation_time.hpp"
#include <limits>
#include <optional>

namespace telar::runtime {

struct AgentSignal {
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  Byte confidence = 0;
  bool identity_confirmed = false;
  bool ready_confirmed = false;

  bool operator==(const AgentSignal &) const = default;
};

struct AgentEvidence {
  AgentProvider provider = AgentProvider::unknown;
  AgentStatus status = AgentStatus::unknown;
  AgentSource source = AgentSource::screen;
  Byte confidence = 0;
  ObservationTime observed;
  std::int64_t expires_at = 0;

  bool expired(std::int64_t now) const noexcept {
    return expires_at <= now;
  }

  static AgentEvidence process(AgentProvider provider, ObservationTime now) noexcept {
    return {provider, AgentStatus::ready, AgentSource::foreground_process, 100, now, std::numeric_limits<std::int64_t>::max()};
  }

  static AgentEvidence screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept {
    return {provider, signal.status, AgentSource::screen, signal.confidence, now, now.milliseconds + (signal.status == AgentStatus::working ? screen_working_expiry : settled_expiry).count()};
  }

  static AgentEvidence report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept {
    const bool working = state == AgentReportState::working || state == AgentReportState::waiting || state == AgentReportState::settling;
    const auto expiry = working ? (state == AgentReportState::settling ? screen_working_expiry : report_working_expiry) : settled_expiry;
    const auto status = working ? AgentStatus::working : state == AgentReportState::blocked ? AgentStatus::blocked
                                                                                            : AgentStatus::ready;
    return {provider, status, AgentSource::lifecycle_report, 100, now, now.milliseconds + expiry.count()};
  }

  static constexpr std::chrono::milliseconds screen_working_expiry{120'000};
  static constexpr std::chrono::milliseconds report_working_expiry{600'000};
  static constexpr std::chrono::milliseconds settled_expiry{1'800'000};
  static constexpr std::chrono::milliseconds renewal_margin{300'000};
};

inline bool completionRequiresSignal(AgentProvider provider) noexcept {
  return provider == AgentProvider::codex || provider == AgentProvider::pi || provider == AgentProvider::cursor || provider == AgentProvider::opencode;
}

}
