#include "allocation_gate.hpp"
#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "presentation/project_activity.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/label_text.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <span>
#include <string>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

void projectCountsAndAttention() {
  SystemAllocator memory;
  WorkspaceReplica workspaces{memory};
  const std::array entries{
      WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"},
      WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"},
      WorkspaceListEntry{.workspace = 3, .name = "other", .path = "/other"},
  };
  const std::array tasks{
      WorktreeListEntry{.worktree = 1, .source = 1, .workspace = 2, .path = "/task", .branch = "worktree-task"},
      WorktreeListEntry{.worktree = 2, .source = 1, .path = "/task-two", .branch = "worktree-two"},
      WorktreeListEntry{.worktree = 3, .source = 3, .path = "/task-three", .branch = "worktree-three"},
  };
  workspaces.apply({.revision = 1, .entries = entries, .worktrees = tasks});
  std::array agents{Agent{memory}, Agent{memory}, Agent{memory}, Agent{memory}, Agent{memory}};
  for (auto &agent : agents) {
    agent.location.workspace = {.id = 2};
    agent.status = AgentStatus::working;
  }

  agents[1].location.workspace.id = 1;
  agents[2].status = AgentStatus::ready;
  agents[3].status = AgentStatus::blocked;
  constexpr std::uint32_t older_status_age = 5;
  agents[3].status_age_s = older_status_age;
  agents[4].status = AgentStatus::failed;
  agents[4].status_age_s = 2;
  const auto activity = ProjectActivity::derive(workspaces, std::span<const Agent<SystemAllocator>>{agents}, 1);
  require(activity.worktrees == 2 && activity.working == 1 && activity.finished == 1, "only task agents in this project contribute to worktree progress");
  require(activity.waiting == 2 && activity.urgent == 4, "project attention must use the shared priority rather than status severity");
  ProjectActivity::Text text;
  require(activity.summary(text) == "\u2387 2 \u00b7 \u25cc 1 \u2713 1  /project", "project facts must preserve the original symbols and spacing");
  require(activity.attentionLabel().view() == "! 2", "attention must count both blocked and failed agents");
  agents[3].location.workspace.kind = WorkspaceLocation::Kind::worktree;
  agents[4].location.workspace.id = 3;
  const auto filtered = ProjectActivity::derive(workspaces, std::span<const Agent<SystemAllocator>>{agents}, 1);
  require(filtered.waiting == 0 && !filtered.urgent, "unattached worktree locations and other projects must not request attention here");
}

void summaryOverflowAndWarmReuse() {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    WorkspaceReplica workspaces{memory};
    const std::string path(label_text_capacity, '/');
    const std::array entries{WorkspaceListEntry{.workspace = 1, .name = "project", .path = path}};
    const std::array tasks{WorktreeListEntry{.worktree = 1, .source = 1, .path = "/task", .branch = "worktree-task"}};
    workspaces.apply({.revision = 1, .entries = entries, .worktrees = tasks});
    const auto allocations = budget.allocations();
    memory.permit(0);
    constexpr std::size_t repetitions = 100;
    for (std::size_t index = 0; index < repetitions; ++index) {
      const auto activity = ProjectActivity::derive(workspaces, std::span<const Agent<decltype(memory)>>{}, 1);
      ProjectActivity::Text text;
      require(!activity.summary(text), "an overflowing summary must preserve the original path fallback");
      require(activity.attentionLabel().view().empty(), "a project without waiting agents must reserve no title space");
    }

    require(budget.allocations() == allocations, "project projection must not allocate through the injected allocator");
    const auto missing = ProjectActivity::derive(workspaces, std::span<const Agent<decltype(memory)>>{}, 2);
    ProjectActivity::Text text;
    require(!missing.summary(text), "a missing project must not publish a summary");
  }

  require(budget.liveBytes() == 0, "project replica destruction must release its injected storage");
}

}

int main() try {
  projectCountsAndAttention();
  summaryOverflowAndWarmReuse();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
