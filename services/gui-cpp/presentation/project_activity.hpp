#pragma once

#include "agent_order.hpp"
#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "core/memory.hpp"
#include "text/bounded_text.hpp"
#include "text/label_text.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

struct ProjectActivity {
  static constexpr std::size_t attention_capacity = 8;
  using Text = LabelText;
  using Attention = BoundedText<attention_capacity>;

  std::size_t worktrees = 0;
  std::size_t working = 0;
  std::size_t finished = 0;
  std::size_t waiting = 0;
  std::optional<std::size_t> urgent;
  std::optional<std::string_view> path;

  template <Allocator Memory>
  [[nodiscard]] static ProjectActivity derive(const WorkspaceReplica<Memory> &workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept {
    ProjectActivity result;
    result.worktrees = static_cast<std::size_t>(std::ranges::count(workspaces.worktrees(), project, &Worktree<Memory>::source));
    const auto index = workspaces.indexOf(project);
    if (index < workspaces.entries().size()) {
      result.path = workspaces.entries()[index].path;
    }

    for (std::size_t index = 0; index < agents.size(); ++index) {
      const auto &agent = agents[index];
      if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspaces.projectOf(agent.location.workspace.id) != project) {
        continue;
      }

      if (workspaces.worktreeOfWorkspace(agent.location.workspace.id) != nullptr || workspaces.worktree(agent.work_tree) != nullptr) {
        result.working += static_cast<std::size_t>(agent.status == AgentStatus::working);
        result.finished += static_cast<std::size_t>(agent.status == AgentStatus::done || agent.status == AgentStatus::ready);
      }

      if (AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input) {
        ++result.waiting;
        if (!result.urgent || AgentOrder::priority(agent) < AgentOrder::priority(agents[*result.urgent])) {
          result.urgent = index;
        }
      }
    }

    return result;
  }

  [[nodiscard]] std::optional<std::string_view> summary(Text &storage) const {
    storage.truncate(0);
    if (worktrees == 0 || !path) {
      return std::nullopt;
    }

    storage.append("\u2387 ");
    storage.appendDecimal(worktrees);
    storage.append(" \u00b7 \u25cc ");
    storage.appendDecimal(working);
    storage.append(" \u2713 ");
    storage.appendDecimal(finished);
    storage.append("  ");
    if (path->size() > label_text_capacity - storage.view().size()) {
      return std::nullopt;
    }

    storage.append(*path);

    return storage.view();
  }

  [[nodiscard]] Attention attentionLabel() const {
    Attention label;
    if (waiting != 0) {
      label.append("! ");
      label.appendDecimal(waiting);
    }

    return label;
  }
};

}
