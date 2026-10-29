#pragma once

#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstdint>
#include <optional>

namespace telar::gui {

template <typename Agent>
concept CompletionAgent = requires(const Agent &agent) {
  { agent.pane_id } -> std::convertible_to<std::uint64_t>;
  { agent.pane_generation } -> std::convertible_to<std::uint64_t>;
  { agent.status } -> std::convertible_to<AgentStatus>;
};

class AgentAcknowledgement {
public:
  template <CompletionAgent Agent>
  [[nodiscard]] std::optional<AcknowledgeAgent> take(const Agent *agent) noexcept {
    if (agent == nullptr) {
      return std::nullopt;
    }

    const bool already = acknowledged_ && acknowledged_->pane_id == agent->pane_id && acknowledged_->pane_generation == agent->pane_generation;
    if (agent->status != AgentStatus::done) {
      if (already) {
        acknowledged_.reset();
      }

      return std::nullopt;
    }

    if (already) {
      return std::nullopt;
    }

    acknowledged_ = AcknowledgeAgent{agent->pane_id, agent->pane_generation};

    return acknowledged_;
  }

private:
  std::optional<AcknowledgeAgent> acknowledged_;
};

}
