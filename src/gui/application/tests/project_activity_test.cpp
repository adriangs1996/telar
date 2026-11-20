#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "foundation/core/memory.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>

import telar.testing;
import telar.testing.test_memory;
import telar.gui.tests.allocation_gate;
import telar.gui.application;
import telar.gui.foundation.text;
import telar.gui.foundation.model;
import telar.gui.features.activity;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::activity;
  using namespace telar::gui::test;

  void projectCountsAndAttention() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WorkspaceReplica workspaces{memory};
    const ds::Array entries{
        WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"},
        WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"},
        WorkspaceListEntry{.workspace = 3, .name = "other", .path = "/other"},
    };

    const ds::Array tasks{
        WorktreeListEntry{.worktree = 1, .source = 1, .workspace = 2, .path = "/task", .branch = "worktree-task"},
        WorktreeListEntry{.worktree = 2, .source = 1, .path = "/task-two", .branch = "worktree-two"},
        WorktreeListEntry{.worktree = 3, .source = 3, .path = "/task-three", .branch = "worktree-three"},
    };

    workspaces.apply({.revision = 1, .entries = entries, .worktrees = tasks});
    ds::Array agents{Agent{memory}, Agent{memory}, Agent{memory}, Agent{memory}, Agent{memory}};

    for (auto& agent : agents.viewMut()) {
      agent.location.workspace = {.id = 2};
      agent.status = AgentStatus::working;
    }

    agents.atMut(1).location.workspace.id = 1;
    agents.atMut(2).status = AgentStatus::ready;
    agents.atMut(3).status = AgentStatus::blocked;
    constexpr std::uint32_t older_status_age = 5;

    agents.atMut(3).status_age_s = older_status_age;
    agents.atMut(4).status = AgentStatus::failed;
    agents.atMut(4).status_age_s = 2;
    const auto activity = ProjectActivity::derive(workspaces, std::span<const Agent<telar::ConcurrentMemory>>{agents}, 1);

    check(activity.worktrees == 2 && activity.working == 1 && activity.finished == 1, "only task agents in this project contribute to worktree progress");
    check(activity.waiting == 2 && activity.urgent == 4U, "project attention must use the shared priority rather than status severity");
    ProjectActivity::Text text;

    check(activity.summary(text) == "\u2387 2 \u00b7 \u25cc 1 \u2713 1  /project", "project facts must preserve the original symbols and spacing");
    check(activity.attentionLabel().view() == "! 2", "attention must count both blocked and failed agents");
    agents.atMut(3).location.workspace.kind = WorkspaceLocation::Kind::worktree;
    agents.atMut(4).location.workspace.id = 3;
    const auto filtered = ProjectActivity::derive(workspaces, std::span<const Agent<telar::ConcurrentMemory>>{agents}, 1);

    check(filtered.waiting == 0 && !filtered.urgent, "unattached worktree locations and other projects must not request attention here");
  }

  void summaryOverflowAndWarmReuse() {
    SystemAllocator upstream;
    BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
    AllocationGate gate{budget};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;

    {
      WorkspaceReplica workspaces{memory};
      const std::string path(label_text_capacity, '/');
      const ds::Array entries{WorkspaceListEntry{.workspace = 1, .name = "project", .path = path}};
      const ds::Array tasks{WorktreeListEntry{.worktree = 1, .source = 1, .path = "/task", .branch = "worktree-task"}};

      workspaces.apply({.revision = 1, .entries = entries, .worktrees = tasks});
      const auto allocations = budget.allocations();

      gate.permit(0);
      constexpr std::size_t repetitions = 100;

      for (std::size_t index = 0; index < repetitions; ++index) {
        const auto activity = ProjectActivity::derive(workspaces, std::span<const Agent<std::remove_reference_t<std::remove_reference_t<decltype(memory)>>>>{}, 1);
        ProjectActivity::Text text;

        check(!activity.summary(text), "an overflowing summary must preserve the original path fallback");
        check(activity.attentionLabel().view().empty(), "a project without waiting agents must reserve no title space");
      }

      check(budget.allocations() == allocations, "project projection must not allocate through the injected allocator");
      const auto missing = ProjectActivity::derive(workspaces, std::span<const Agent<std::remove_reference_t<std::remove_reference_t<decltype(memory)>>>>{}, 2);
      ProjectActivity::Text text;

      check(!missing.summary(text), "a missing project must not publish a summary");
    }

    check(budget.liveBytes() == 0, "project replica destruction must release its injected storage");
  }

  const telar::testing::Case case_project_counts_and_attention{"project_activity.project_counts_and_attention", projectCountsAndAttention};
  const telar::testing::Case case_summary_overflow_and_warm_reuse{"project_activity.summary_overflow_and_warm_reuse", summaryOverflowAndWarmReuse};

}
