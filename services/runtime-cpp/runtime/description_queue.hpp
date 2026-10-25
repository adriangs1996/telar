#pragma once

#include "../agents/registry.hpp"
#include "../history/event.hpp"
#include <algorithm>

namespace telar::runtime {

template <Allocator Memory>
class DescriptionQueue {
public:
  explicit DescriptionQueue(AgentRegistry<Memory> &agents)
      : agents_(agents) {}

  void enable(bool enabled) noexcept {
    descriptions_enabled_ = enabled;
  }

  bool enabled() const noexcept {
    return descriptions_enabled_;
  }

  void project(Agent &agent) noexcept {
    if (descriptions_enabled_ && agent.description_phase == DescriptionPhase::waiting_work) {
      const auto pending = std::ranges::count_if(agents_.records(), [](const auto &entry) { return entry->hasPendingDescription(); });
      if (static_cast<std::size_t>(pending) < description_queue_capacity) {
        agent.queueDescription();
      }
    }
  }

  std::optional<DescriptionRequest> nextDescription() {
    std::size_t pending = 0;
    for (const auto &agent : agents_.records()) {
      if (agent->description_phase == DescriptionPhase::running) {
        return std::nullopt;
      }

      pending += agent->hasPendingDescription();
    }

    for (auto &agent : agents_.records()) {
      if (pending < description_queue_capacity && agent->queueDescription()) {
        ++pending;
        agents_.changed();
      }
    }

    for (auto &agent : agents_.records()) {
      if (agent->description_phase != DescriptionPhase::queued) {
        continue;
      }

      try {
        auto query = agent->description_capture.normalized();
        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::running;
        agent->description_revision = ++description_revision_;
        return DescriptionRequest{.identity = {agent->pane, agent->generation, agent->session_id, agent->description_revision}, .query = std::move(query)};
      } catch (const EncodingError &) {
        agent->description_capture.clear();
        agent->description_phase = DescriptionPhase::failed;
        agent->title_state = AgentTitleState::failed;
        agents_.changed();
      }
    }

    return std::nullopt;
  }

  std::optional<HistorySessionTitle> completeDescription(const DescriptionResult &result) {
    auto *agent = agents_.find(result.identity.pane, result.identity.generation);
    if (agent == nullptr || agent->description_phase != DescriptionPhase::running || agent->session_id != result.identity.session || agent->description_revision != result.identity.revision) {
      return std::nullopt;
    }

    HistorySessionTitle finished{.session = agent->session_id};
    if (result.status == DescriptionStatus::success) {
      try {
        finished.title = normalizeDescriptionTitle(result.title.view());
        finished.source = AgentTitleSource::generated;
        finished.state = AgentTitleState::ready;
      } catch (const EncodingError &) {
      }
    }

    if (finished.state == AgentTitleState::ready) {
      agent->title = finished.title;
      agent->title_source = finished.source;
      agent->finishTitleCapture();
    } else {
      agent->description_phase = DescriptionPhase::failed;
    }

    agent->title_state = finished.state;
    agents_.changed();
    return finished;
  }

private:
  static constexpr std::size_t description_queue_capacity = 8;
  AgentRegistry<Memory> &agents_;
  std::uint64_t description_revision_ = 0;
  bool descriptions_enabled_ = false;
};

}
