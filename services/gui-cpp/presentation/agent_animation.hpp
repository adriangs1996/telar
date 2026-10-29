#pragma once

#include "agent_status.hpp"
#include "status_age.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

struct AgentAnimation {
  static constexpr std::uint64_t pulse_interval_ns = 120'000'000;

  [[nodiscard]] static float alpha(std::uint64_t now_ns) noexcept {
    return AgentStatusPresentation::pulse(static_cast<std::uint8_t>(now_ns / pulse_interval_ns));
  }

  [[nodiscard]] static std::optional<std::uint64_t> deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept {
    if (!connected || (status != AgentStatus::working && status != AgentStatus::ready)) {
      return std::nullopt;
    }

    const auto interval = status == AgentStatus::working ? pulse_interval_ns : StatusAgeInterval::nanoseconds_per_second;
    const auto remaining = interval - (now_ns % interval);

    return now_ns + std::min(std::numeric_limits<std::uint64_t>::max() - now_ns, remaining);
  }
};

}
