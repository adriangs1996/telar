#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstring>
#include <new>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;

import telar.gui.foundation.core;
import telar.gui.tests.activity_fixture;
import telar.gui.tests.agent_fixture;
import telar.gui.tests.allocation_gate;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.features.activity;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.gui.foundation.model;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::activity;
  using namespace telar::gui::test;
  using namespace telar::gui::application::tests::session_fixture;

  void workspaceMetadataAndRevisions() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WorkspaceReplica replica{memory};
    const ds::Array projects{WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"}, WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project", .tab_count = 3}};
    const ds::Array rows{worktreeEntry()};

    check(replica.apply({.revision = 1, .entries = projects, .worktrees = rows}), "workspace snapshots must commit");
    check(replica.entries().size() == 2 && replica.projects().size() == 1 && replica.entries().front().location.id == 1, "project rows must precede worktree workspaces without duplicating them");
    check(replica.entries().front().tab_count == 3 && replica.projectOf(2) == 1, "workspace ownership and tab metadata must survive projection");
    check(replica.worktree(task_worktree_id) == replica.worktreeOfWorkspace(2), "worktree and workspace identities must resolve the same row");
    check(replica.worktree(task_worktree_id)->handle() == "fix" && replica.worktree(task_worktree_id)->displayName() == "Fix the task", "task labels must retain original prefix handling");
    check(!replica.apply({.revision = 1, .entries = {}}) && replica.entries().size() == 2, "stale revisions must preserve the current replica");
    const ds::Array duplicates{projects.front(), projects.front()};
    bool rejected = false;

    try {
      replica.apply({.revision = 2, .entries = duplicates});
    } catch (const std::invalid_argument&) {
      rejected = true;
    }

    check(rejected && replica.revision() == 1 && replica.projects().size() == 1, "duplicate workspace rejection must preserve published rows");
    replica.resetSource();
    check(replica.apply({.revision = 1, .entries = projects, .worktrees = rows}), "a replacement runtime may restart workspace revisions");
  }

  void pathPoolAndAllocationFailure() {
    SystemAllocator upstream;
    BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
    AllocationGate gate{budget};
    telar::MemoryAdapter adapter{gate};
    telar::Memory& memory = adapter;

    {
      WorkspaceReplica replica{memory};
      constexpr std::size_t maximum_path_bytes = 4096;
      constexpr std::size_t entry_count = 9;
      const std::string path(maximum_path_bytes, '/');
      ds::Array<WorkspaceListEntry, entry_count> projects;

      for (std::size_t index = 0; index < projects.size(); ++index) {
        projects.atMut(index) = {.workspace = index + 1, .name = "project", .path = path};
      }

      ds::Array tasks{worktreeEntry()};

      tasks.atMut(0).path = path;
      replica.apply({.revision = 1, .entries = projects, .worktrees = tasks});
      replica.apply({.revision = 2, .entries = projects, .worktrees = tasks});
      check(replica.entries().size() == WorkspaceReplica<std::remove_reference_t<std::remove_reference_t<decltype(memory)>>>::path_pool_bytes / maximum_path_bytes && replica.dropped() == 1, "the original path pool keeps only complete paths before its first overflow");
      check(replica.worktrees().front().path.size() == Worktree<std::remove_reference_t<std::remove_reference_t<decltype(memory)>>>::retained_path_bytes, "task metadata keeps the original bounded checkout-path tail");
      const auto live = budget.liveBytes();
      const std::string title(80, 'x');

      tasks.atMut(0).title = title;
      gate.permit(0);
      bool rejected = false;

      try {
        replica.apply({.revision = 3, .entries = projects, .worktrees = tasks});
      } catch (const std::bad_alloc&) {
        rejected = true;
      }

      check(rejected && replica.revision() == 2 && replica.worktrees().front().title == "Fix the task", "worktree allocation failure must preserve the entire published snapshot");
      check(budget.liveBytes() == live, "rejected metadata must not leak storage");
      gate.permit(ds::none);
      check(replica.apply({.revision = 3, .entries = projects, .worktrees = tasks}), "failed workspace snapshots must be retryable");
    }

    check(budget.liveBytes() == 0, "workspace replicas must release all injected allocations");
  }

  void activityNestsTasksAndCommands() {
    SystemAllocator upstream;
    BudgetAllocator allocator{upstream, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{allocator};
    telar::Memory& memory = adapter;
    WorkspaceReplica workspaces{memory};
    AgentReplica agents{memory};
    const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"}};
    ds::Array tasks{worktreeEntry(), worktreeEntry()};

    tasks.atMut(tasks.size() - 1).worktree = command_worktree_id;
    tasks.atMut(tasks.size() - 1).workspace.reset();
    tasks.atMut(tasks.size() - 1).command_state = CommandState::exited;
    tasks.atMut(tasks.size() - 1).command_label = "test";
    check(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}), "activity workspaces must commit");
    ds::Array reports{agentSnapshotEntry(), agentSnapshotEntry()};

    reports.atMut(reports.size() - 1).pane_id = 2;
    reports.atMut(reports.size() - 1).location.workspace.id = 2;
    reports.atMut(reports.size() - 1).work_tree = task_worktree_id;
    reports.atMut(reports.size() - 1).status = AgentStatus::blocked;
    check(agents.apply({.revision = 1, .entries = reports}, 0), "activity agents must commit");
    using Order = ActivityOrder<std::remove_reference_t<std::remove_reference_t<decltype(memory)>>>;
    const ds::Array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
    Order::Plan plan;
    const auto allocations = allocator.allocations();

    Order::write(sources, 0, plan);
    check(allocator.allocations() == allocations, "activity ordering must not allocate");
    check(plan.count == 3 && plan.entries.front().agent == 0 && plan.entries.front().coordinator, "the root agent must own its task and tracked command");
    check(plan.entries[1].agent == 1 && plan.entries[1].parent == 0 && plan.entries[1].depth == 1 && plan.entries[1].card == ActivityCard::task, "tasks must be nested under their creator");
    check(!plan.entries[2].agent && plan.entries[2].worktree == 1 && plan.entries[2].parent == 0, "an unrepresented tracked command must remain visible under its creator");
  }

  void exactReferencesAndCycles() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WorkspaceReplica workspaces{memory};
    AgentReplica agents{memory};
    const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
    ds::Array reports{agentSnapshotEntry(), agentSnapshotEntry()};

    reports.atMut(0).work_tree = task_worktree_id;
    reports.atMut(0).session_id = coordinatorReference(1).session_id;
    reports.atMut(reports.size() - 1).session_id = coordinatorReference(2).session_id;
    reports.atMut(reports.size() - 1).pane_id = 2;
    reports.atMut(reports.size() - 1).work_tree = command_worktree_id;
    ds::Array tasks{worktreeEntry(), worktreeEntry()};

    tasks.atMut(0).coordinator = coordinatorReference(2);
    tasks.atMut(tasks.size() - 1).worktree = command_worktree_id;
    tasks.atMut(tasks.size() - 1).workspace.reset();
    tasks.atMut(tasks.size() - 1).coordinator = coordinatorReference(1);
    check(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}), "cyclic workspaces must be retained");
    check(agents.apply({.revision = 1, .entries = reports}, 0), "cyclic agents must be retained");
    using Order = ActivityOrder<telar::ConcurrentMemory>;
    const ds::Array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
    Order::Plan plan;

    Order::write(sources, 0, plan);
    check(plan.count == 2 && !plan.entries[0].parent && plan.entries[1].parent == 0 && plan.entries[1].depth == 1, "cyclic attribution must break only its cyclic edge without losing cards");
    tasks.atMut(0).coordinator = coordinatorReference(2, 2);
    check(workspaces.apply({.revision = 2, .entries = projects, .worktrees = tasks}), "stale coordinator references remain representable");
    Order::write(sources, 0, plan);
    check(!plan.entries[0].parent, "an explicit stale reference must not fall back to a coincident pane id");
    Agent agent{memory};

    agent.final_message.assign("\n \t\n  Final answer\t\nother");
    check(agent.finalLine() == "Final answer", "task summaries must use the original first nonempty line");
  }

  void crossMachineAliasesResolveDeterministically() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WorkspaceReplica parent_workspaces{memory};
    WorkspaceReplica child_workspaces{memory};
    AgentReplica parents{memory};
    AgentReplica children{memory};
    const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
    ds::Array rows{worktreeEntry()};

    rows.atMut(0).coordinator = coordinatorReference(1);
    const ds::Array parent_reports{agentSnapshotEntry()};
    auto report = parent_reports.front();

    // Other machines contribute only the agents that wait on the person.
    report.status = AgentStatus::blocked;
    report.session_id = coordinatorReference(1).session_id;
    const ds::Array identified_parents{report};

    report.pane_id = 2;
    report.work_tree = task_worktree_id;
    report.final_message = "\n A retained answer\n";
    const ds::Array child_reports{report};

    parent_workspaces.apply({.revision = 1, .entries = projects});
    child_workspaces.apply({.revision = 1, .entries = projects, .worktrees = rows});
    parents.apply({.revision = 1, .entries = identified_parents}, 0);
    children.apply({.revision = 1, .entries = child_reports}, 0);
    check(children.entries().front().finalLine() == "A retained answer", "runtime task summaries must retain their owned final message");
    using Order = ActivityOrder<telar::ConcurrentMemory>;
    const ds::Array sources{
        Order::Source{.slot = 0, .agents = parents.entries(), .workspaces = parent_workspaces},
        Order::Source{.slot = 1, .agents = parents.entries(), .workspaces = parent_workspaces},
        Order::Source{.slot = 2, .agents = children.entries(), .workspaces = child_workspaces},
    };

    Order::Plan plan;

    Order::write(sources, 0, plan);
    check(plan.count == 3 && plan.entries[1].source == 2 && plan.entries[1].parent == 0 && plan.entries[2].source == 1, "aliased runtime identities must choose the first exact coordinator without hiding either alias");
  }

  void otherMachinesListOnlyAgentsThatWait() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WorkspaceReplica workspaces{memory};
    AgentReplica agents{memory};
    const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
    ds::Array rows{worktreeEntry()};

    rows.atMut(0).worktree = command_worktree_id;
    rows.atMut(0).workspace.reset();
    rows.atMut(0).command_state = CommandState::running;
    rows.atMut(0).command_label = "test";
    check(workspaces.apply({.revision = 1, .entries = projects, .worktrees = rows}), "workspaces must commit");
    ds::Array reports{agentSnapshotEntry(), agentSnapshotEntry(), agentSnapshotEntry()};

    reports.atMut(0).status = AgentStatus::working;
    reports.atMut(1).pane_id = 2;
    reports.atMut(1).status = AgentStatus::blocked;
    reports.atMut(2).pane_id = 3;
    reports.atMut(2).status = AgentStatus::failed;
    check(agents.apply({.revision = 1, .entries = reports}, 0), "agents must commit");
    using Order = ActivityOrder<telar::ConcurrentMemory>;
    const ds::Array sources{
        Order::Source{.slot = 0, .agents = agents.entries(), .workspaces = workspaces},
        Order::Source{.slot = 1, .agents = agents.entries(), .workspaces = workspaces},
    };

    Order::Plan plan;

    Order::write(sources, 0, plan);
    std::size_t active = 0;
    std::size_t other = 0;

    for (const auto& entry : plan.view()) {
      if (entry.source == 0) {
        ++active;
        continue;
      }

      ++other;
      check(entry.agent && AgentOrder::attention(agents.entries()[*entry.agent].status) == AgentOrder::Attention::needs_input, "another machine lists only agents that wait on the person");
    }

    check(active == 4 && other == 2, "the active machine keeps every agent and command; another keeps its blocked and failed agents");
  }

  void commandNavigationUsesTheCurrentWorkspace() {
    SystemAllocator memory;
    Transport transport;
    TestSession session{memory, transport};
    ds::Array rows{worktreeEntry()};
    const ds::Array entries{WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/project/worktree"}};

    deliver(session, WorkspaceList{.revision = 1, .entries = entries, .worktrees = rows});
    check(!application::workbench::openWorktree(session, task_worktree_id), "offline metadata must not navigate to a retired runtime");
    session.connected(1);
    check(!application::workbench::openWorktree(session, task_worktree_id), "a new connection must wait for refreshed workspace metadata");
    deliver(session, WorkspaceList{.revision = 1, .entries = entries, .worktrees = rows});
    check(application::workbench::openWorktree(session, task_worktree_id), "tracked command navigation must select its workspace");
    const auto request = transport.last<OpenPane>();

    check(request.target.kind == PaneTarget::Kind::workspace && request.target.id == 2 && !request.launch, "command navigation must open the materialized workspace without launching another command");
    deliver(session, RequestFailed{.request_id = request.request_id, .code = FailureCode::permission_denied, .message = "Workspace access was denied"});
    check(!session.requestsPending(), "the detached-worktree check must not be masked by an in-flight navigation request");
    rows.atMut(0).workspace.reset();
    deliver(session, WorkspaceList{.revision = 2, .entries = entries, .worktrees = rows});
    const auto requests = transport.sent.size();

    check(!application::workbench::openWorktree(session, task_worktree_id) && transport.sent.size() == requests, "a detached worktree must not reuse its previous workspace");
  }

  const telar::testing::Case case_workspace_metadata_and_revisions{"activity.workspace_metadata_and_revisions", workspaceMetadataAndRevisions};
  const telar::testing::Case case_path_pool_and_allocation_failure{"activity.path_pool_and_allocation_failure", pathPoolAndAllocationFailure};
  const telar::testing::Case case_activity_nests_tasks_and_commands{"activity.activity_nests_tasks_and_commands", activityNestsTasksAndCommands};
  const telar::testing::Case case_exact_references_and_cycles{"activity.exact_references_and_cycles", exactReferencesAndCycles};
  const telar::testing::Case case_cross_machine_aliases_resolve_deterministically{"activity.cross_machine_aliases_resolve_deterministically", crossMachineAliasesResolveDeterministically};
  const telar::testing::Case case_other_machines_list_only_agents_that_wait{"activity.other_machines_list_only_agents_that_wait", otherMachinesListOnlyAgentsThatWait};
  const telar::testing::Case case_command_navigation_uses_the_current_workspace{"activity.command_navigation_uses_the_current_workspace", commandNavigationUsesTheCurrentWorkspace};

}
