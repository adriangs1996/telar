#pragma once

#include "activity_card.hpp"
#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <tuple>

namespace telar::gui {

struct AgentOrder {
  static constexpr std::size_t maximum_agents = 64;
  static constexpr std::size_t unknown_project = std::numeric_limits<std::size_t>::max();

  enum class Attention : std::uint8_t {
    needs_input,
    working,
    done,
    ready,
    unknown,
  };

  struct Entry {
    std::size_t agent = 0;
    std::optional<std::uint64_t> project = std::nullopt;
    std::optional<std::size_t> creator = std::nullopt;
    ActivityCard card = ActivityCard::agent;
    bool first_in_project = false;
  };

  struct Plan {
    std::array<Entry, maximum_agents> entries{};
    std::size_t count = 0;

    [[nodiscard]] std::span<const Entry> view() const noexcept {
      return std::span{entries}.first(count);
    }
  };

  [[nodiscard]] static Attention attention(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::blocked:
    case AgentStatus::failed:
      return Attention::needs_input;
    case AgentStatus::working:
      return Attention::working;
    case AgentStatus::done:
      return Attention::done;
    case AgentStatus::ready:
      return Attention::ready;
    default:
      return Attention::unknown;
    }
  }

  template <Allocator Memory>
  [[nodiscard]] static const Worktree<Memory> *taskRow(const WorkspaceReplica<Memory> &workspaces, const Agent<Memory> &agent) noexcept {
    if (const auto *row = workspaces.worktree(agent.work_tree)) {
      return row;
    }

    return agent.location.workspace.kind == WorkspaceLocation::Kind::workspace ? workspaces.worktreeOfWorkspace(agent.location.workspace.id) : nullptr;
  }

  template <Allocator Memory>
  [[nodiscard]] static auto priority(const Agent<Memory> &agent) noexcept {
    return std::tuple{attention(agent.status), agent.status_age_s, agent.pane_id, agent.pane_generation};
  }

  template <Allocator Memory>
  [[nodiscard]] static Plan arrange(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory> &workspaces, std::optional<std::uint64_t> focused = std::nullopt) noexcept {
    Plan plan;
    plan.count = std::min(agents.size(), maximum_agents);
    const auto entries = std::span{plan.entries}.first(plan.count);
    for (std::size_t index = 0; index < plan.count; ++index) {
      const auto &agent = agents[index];
      const auto *row = taskRow(workspaces, agent);
      const auto project = projectOf(workspaces, agent);
      entries[index] = {.agent = index, .project = project, .card = cardFor(agent, row != nullptr, focused)};
    }

    for (auto &entry : entries) {
      entry.creator = creatorOf(agents, workspaces, entries, entry);
    }

    std::ranges::sort(entries, [&](const Entry &left, const Entry &right) {
      return lessThan(agents, workspaces, left, right);
    });
    for (std::size_t index = 0; index < entries.size(); ++index) {
      entries[index].first_in_project = index == 0 || entries[index].project != entries[index - 1].project;
    }

    return plan;
  }

private:
  template <Allocator Memory>
  [[nodiscard]] static ActivityCard cardFor(const Agent<Memory> &agent, bool task, std::optional<std::uint64_t> focused) noexcept {
    if (!task) {
      return ActivityCard::agent;
    }

    if (focused == agent.pane_id || agent.status == AgentStatus::blocked || agent.status == AgentStatus::failed || agent.status == AgentStatus::done) {
      return ActivityCard::task_full;
    }

    return ActivityCard::task_compact;
  }

  template <Allocator Memory>
  [[nodiscard]] static std::size_t projectRank(std::optional<std::uint64_t> identity, std::span<const Workspace<Memory>> workspaces) noexcept {
    if (identity) {
      for (std::size_t index = 0; index < workspaces.size(); ++index) {
        if (workspaces[index].location.kind == WorkspaceLocation::Kind::workspace && *identity == workspaces[index].location.id) {
          return index;
        }
      }
    }

    return unknown_project;
  }

  template <Allocator Memory>
  [[nodiscard]] static std::optional<std::uint64_t> projectOf(const WorkspaceReplica<Memory> &workspaces, const Agent<Memory> &agent) noexcept {
    if (const auto *row = workspaces.worktree(agent.work_tree)) {
      return row->source;
    }

    if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace) {
      return std::nullopt;
    }

    const auto project = workspaces.projectOf(agent.location.workspace.id);

    return workspaces.indexOf(project) < workspaces.entries().size() ? std::optional{project} : std::nullopt;
  }

  template <Allocator Memory>
  [[nodiscard]] static std::optional<std::size_t> creatorOf(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory> &workspaces, std::span<const Entry> entries, const Entry &entry) noexcept {
    const auto *row = entry.card == ActivityCard::agent ? nullptr : taskRow(workspaces, agents[entry.agent]);
    if (row == nullptr) {
      return std::nullopt;
    }

    for (const auto &candidate : entries) {
      const auto &parent = agents[candidate.agent];
      if (candidate.agent == entry.agent || candidate.card != ActivityCard::agent || candidate.project != entry.project) {
        continue;
      }

      if (row->coordinator) {
        const auto &reference = *row->coordinator;
        if (parent.pane_id == reference.pane_id && parent.pane_generation == reference.pane_generation && parent.session_id == reference.session_id) {
          return candidate.agent;
        }
      } else if (row->created_by == parent.pane_id) {
        return candidate.agent;
      }
    }

    return std::nullopt;
  }

  template <Allocator Memory>
  [[nodiscard]] static bool lessThan(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory> &workspaces, const Entry &left, const Entry &right) noexcept {
    const auto rows = std::span<const Workspace<Memory>>{workspaces.entries()};
    const auto left_rank = projectRank(left.project, rows);
    const auto right_rank = projectRank(right.project, rows);
    if (left_rank != right_rank) {
      return left_rank < right_rank;
    }

    const auto left_orphan = left.card != ActivityCard::agent && !left.creator;
    const auto right_orphan = right.card != ActivityCard::agent && !right.creator;
    if (left_orphan != right_orphan) {
      return !left_orphan;
    }

    if (!left_orphan) {
      const auto left_root = left.creator.value_or(left.agent);
      const auto right_root = right.creator.value_or(right.agent);
      if (left_root != right_root) {
        return priority(agents[left_root]) < priority(agents[right_root]);
      }

      if ((left.card == ActivityCard::agent) != (right.card == ActivityCard::agent)) {
        return left.card == ActivityCard::agent;
      }
    }

    if ((left.card == ActivityCard::task_full) != (right.card == ActivityCard::task_full)) {
      return left.card == ActivityCard::task_full;
    }

    return priority(agents[left.agent]) < priority(agents[right.agent]);
  }
};

}
