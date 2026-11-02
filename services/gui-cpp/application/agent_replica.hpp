#pragma once

#include "agent_status_change.hpp"
#include "core/memory.hpp"
#include "presentation/status_age.hpp"
#include "records.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

namespace telar::gui {

template <Allocator Memory>
class AgentReplica {
public:
  static constexpr std::size_t capacity = 64;

  explicit AgentReplica(Memory &memory)
      : memory_(memory),
        entries_(AllocatorRef<Agent<Memory>, Memory>{memory}),
        staging_(AllocatorRef<Agent<Memory>, Memory>{memory}) {}

  [[nodiscard]] const auto &entries() const noexcept {
    return entries_;
  }

  [[nodiscard]] auto begin() const noexcept {
    return entries_.begin();
  }

  [[nodiscard]] auto end() const noexcept {
    return entries_.end();
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::span<const AgentStatusChange> statusChanges() const noexcept {
    return std::span{status_changes_}.first(status_change_count_);
  }

  void resetSource() noexcept {
    revision_ = 0;
    now_ns_ = 0;
    retain_clocks_ = false;
    status_change_count_ = 0;
  }

  bool apply(const AgentSnapshot &snapshot, std::uint64_t now_ns) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    if (snapshot.entries.size() > capacity) {
      throw std::length_error{"TooManyAgents"};
    }

    validate(snapshot);
    prepareStaging(snapshot.entries.size());
    std::array<AgentStatusChange, capacity> status_changes;
    std::size_t status_change_count = 0;
    const auto sample_ns = std::max(now_ns_, now_ns);
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto &entry = snapshot.entries[index];
      auto &agent = staging_[index];
      assign(agent, entry);
      const auto previous = std::ranges::find_if(entries_, [&](const auto &candidate) {
        return candidate.pane_id == entry.pane_id && candidate.pane_generation == entry.pane_generation;
      });
      agent.status_clock = retain_clocks_ && previous != entries_.end() ? previous->status_clock : StatusAge{};
      agent.status_clock.observe({.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .status = agent.status, .provider = agent.provider_kind, .reported_seconds = agent.status_age_s}, sample_ns);

      if (retain_clocks_ && previous != entries_.end() && previous->status != agent.status) {
        status_changes[status_change_count++] = {.pane_id = agent.pane_id, .pane_generation = agent.pane_generation, .pane_index = agent.pane_index, .provider = agent.provider_kind, .previous = previous->status, .current = agent.status};
      }
    }

    entries_.swap(staging_);
    std::ranges::copy(std::span{status_changes}.first(status_change_count), status_changes_.begin());
    status_change_count_ = status_change_count;
    revision_ = snapshot.revision;
    now_ns_ = sample_ns;
    retain_clocks_ = true;

    return true;
  }

private:
  static void validate(const AgentSnapshot &snapshot) {
    for (std::size_t index = 0; index < snapshot.entries.size(); ++index) {
      const auto &entry = snapshot.entries[index];
      BodySchema<AgentSnapshotEntry>::validate(entry);
      for (const auto &previous : snapshot.entries.first(index)) {
        if (previous.pane_id == entry.pane_id && previous.pane_generation == entry.pane_generation) {
          throw std::invalid_argument{"DuplicateAgent"};
        }
      }
    }
  }

  void prepareStaging(std::size_t count) {
    while (staging_.size() > count) {
      staging_.pop_back();
    }

    staging_.reserve(count);
    while (staging_.size() < count) {
      staging_.emplace_back(memory_);
    }
  }

  static void assign(Agent<Memory> &agent, const AgentSnapshotEntry &entry) {
    agent.pane_id = entry.pane_id;
    agent.pane_generation = entry.pane_generation;
    agent.pane_index = entry.pane_index;
    agent.session_id = entry.session_id;
    agent.work_tree = entry.work_tree;
    agent.location = entry.location;
    agent.status = entry.status;
    agent.blocked_reason = entry.blocked_reason;
    agent.provider_kind = entry.provider;
    agent.attachments = entry.attachments;
    agent.title_state = entry.title_state;
    agent.title = entry.session_title;
    agent.provider_name = entry.provider_name;
    agent.workspace_label = entry.workspace_label;
    agent.display_name = entry.display_name;
    agent.icon = entry.icon;
    agent.detail = entry.last_event;
    agent.plan_step = entry.plan_step;
    agent.final_message = entry.final_message;
    agent.plan_done = entry.plan_done;
    agent.plan_total = entry.plan_total;
    agent.status_age_s = entry.status_age_s;
  }

  Memory &memory_;
  Vector<Agent<Memory>, Memory> entries_;
  Vector<Agent<Memory>, Memory> staging_;
  std::array<AgentStatusChange, capacity> status_changes_;
  std::size_t status_change_count_ = 0;
  std::uint64_t revision_ = 0;
  std::uint64_t now_ns_ = 0;
  bool retain_clocks_ = false;
};

}
