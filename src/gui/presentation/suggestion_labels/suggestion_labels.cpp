module telar.gui.presentation.suggestion_labels;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.model;

namespace telar::gui {

  float AgentAnimation::alpha(std::uint64_t now_ns) noexcept {
    return AgentStatusPresentation::pulse(static_cast<std::uint8_t>(now_ns / pulse_interval_ns));
  }

  std::optional<std::uint64_t> AgentAnimation::deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept {
    if (!connected || status == AgentStatus::unknown) {
      return std::nullopt;
    }

    const auto interval = status == AgentStatus::working ? pulse_interval_ns : StatusAgeInterval::nanoseconds_per_second;
    const auto remaining = interval - (now_ns % interval);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }

}
