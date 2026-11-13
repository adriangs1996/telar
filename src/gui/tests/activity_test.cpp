#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>
#include <new>
#include "assertions.hpp"

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.gui.tests.activity_fixture;
import telar.gui.tests.agent_fixture;
import telar.gui.tests.allocation_gate;
import telar.gui.tests.session_fixture;
import telar.gui.application.workspace_replica;
import telar.gui.application.session;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

void workspaceMetadataAndRevisions() {
  SystemAllocator memory;
  WorkspaceReplica replica{memory};
  const std::array projects{WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"}, WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project", .tab_count = 3}};
  std::array rows{worktreeEntry()};
  require(replica.apply({.revision = 1, .entries = projects, .worktrees = rows}), "workspace snapshots must commit");
  require(replica.entries().size() == 2 && replica.projects().size() == 1 && replica.entries().front().location.id == 1, "project rows must precede worktree workspaces without duplicating them");
  require(replica.entries().front().tab_count == 3 && replica.projectOf(2) == 1, "workspace ownership and tab metadata must survive projection");
  require(replica.worktree(task_worktree_id) == replica.worktreeOfWorkspace(2), "worktree and workspace identities must resolve the same row");
  require(replica.worktree(task_worktree_id)->handle() == "fix" && replica.worktree(task_worktree_id)->displayName() == "Fix the task", "task labels must retain original prefix handling");
  require(!replica.apply({.revision = 1, .entries = {}}) && replica.entries().size() == 2, "stale revisions must preserve the current replica");
  const std::array duplicates{projects.front(), projects.front()};
  bool rejected = false;
  try {
    replica.apply({.revision = 2, .entries = duplicates});
  } catch (const std::invalid_argument &) {
    rejected = true;
  }

  require(rejected && replica.revision() == 1 && replica.projects().size() == 1, "duplicate workspace rejection must preserve published rows");
  replica.resetSource();
  require(replica.apply({.revision = 1, .entries = projects, .worktrees = rows}), "a replacement runtime may restart workspace revisions");
}

void pathPoolAndAllocationFailure() {
  SystemAllocator upstream;
  BudgetAllocator budget{upstream, std::numeric_limits<std::size_t>::max()};
  AllocationGate memory{budget};
  {
    WorkspaceReplica replica{memory};
    constexpr std::size_t maximum_path_bytes = 4096;
    constexpr std::size_t entry_count = 9;
    const std::string path(maximum_path_bytes, '/');
    std::array<WorkspaceListEntry, entry_count> projects;
    for (std::size_t index = 0; index < projects.size(); ++index) {
      projects[index] = {.workspace = index + 1, .name = "project", .path = path};
    }

    std::array tasks{worktreeEntry()};
    tasks.front().path = path;
    replica.apply({.revision = 1, .entries = projects, .worktrees = tasks});
    replica.apply({.revision = 2, .entries = projects, .worktrees = tasks});
    require(replica.entries().size() == WorkspaceReplica<decltype(memory)>::path_pool_bytes / maximum_path_bytes && replica.dropped() == 1, "the original path pool keeps only complete paths before its first overflow");
    require(replica.worktrees().front().path.size() == Worktree<decltype(memory)>::retained_path_bytes, "task metadata keeps the original bounded checkout-path tail");
    const auto live = budget.liveBytes();
    const std::string title(80, 'x');
    tasks.front().title = title;
    memory.permit(0);
    bool rejected = false;
    try {
      replica.apply({.revision = 3, .entries = projects, .worktrees = tasks});
    } catch (const std::bad_alloc &) {
      rejected = true;
    }

    require(rejected && replica.revision() == 2 && replica.worktrees().front().title == "Fix the task", "worktree allocation failure must preserve the entire published snapshot");
    require(budget.liveBytes() == live, "rejected metadata must not leak storage");
    memory.permit(std::nullopt);
    require(replica.apply({.revision = 3, .entries = projects, .worktrees = tasks}), "failed workspace snapshots must be retryable");
  }

  require(budget.liveBytes() == 0, "workspace replicas must release all injected allocations");
}

void activityNestsTasksAndCommands() {
  SystemAllocator upstream;
  BudgetAllocator memory{upstream, std::numeric_limits<std::size_t>::max()};
  WorkspaceReplica workspaces{memory};
  AgentReplica agents{memory};
  const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}, WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/task"}};
  std::array tasks{worktreeEntry(), worktreeEntry()};
  tasks.back().worktree = command_worktree_id;
  tasks.back().workspace.reset();
  tasks.back().command_state = CommandState::exited;
  tasks.back().command_label = "test";
  require(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}), "activity workspaces must commit");
  std::array reports{agentSnapshotEntry(), agentSnapshotEntry()};
  reports.back().pane_id = 2;
  reports.back().location.workspace.id = 2;
  reports.back().work_tree = task_worktree_id;
  reports.back().status = AgentStatus::blocked;
  require(agents.apply({.revision = 1, .entries = reports}, 0), "activity agents must commit");
  using Order = ActivityOrder<decltype(memory)>;
  const std::array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
  Order::Plan plan;
  const auto allocations = memory.allocations();
  Order::write(sources, 0, plan);
  require(memory.allocations() == allocations, "activity ordering must not allocate");
  require(plan.count == 3 && plan.entries.front().agent == 0 && plan.entries.front().coordinator, "the root agent must own its task and tracked command");
  require(plan.entries[1].agent == 1 && plan.entries[1].parent == 0 && plan.entries[1].depth == 1 && plan.entries[1].card == ActivityCard::task_full, "blocked tasks must be full cards nested under their creator");
  require(!plan.entries[2].agent && plan.entries[2].worktree == 1 && plan.entries[2].parent == 0, "an unrepresented tracked command must remain visible under its creator");
}

void exactReferencesAndCycles() {
  SystemAllocator memory;
  WorkspaceReplica workspaces{memory};
  AgentReplica agents{memory};
  const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
  std::array reports{agentSnapshotEntry(), agentSnapshotEntry()};
  reports.front().work_tree = task_worktree_id;
  reports.front().session_id = coordinatorReference(1).session_id;
  reports.back().session_id = coordinatorReference(2).session_id;
  reports.back().pane_id = 2;
  reports.back().work_tree = command_worktree_id;
  std::array tasks{worktreeEntry(), worktreeEntry()};
  tasks.front().coordinator = coordinatorReference(2);
  tasks.back().worktree = command_worktree_id;
  tasks.back().workspace.reset();
  tasks.back().coordinator = coordinatorReference(1);
  require(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}), "cyclic workspaces must be retained");
  require(agents.apply({.revision = 1, .entries = reports}, 0), "cyclic agents must be retained");
  using Order = ActivityOrder<SystemAllocator>;
  const std::array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
  Order::Plan plan;
  Order::write(sources, 0, plan);
  require(plan.count == 2 && !plan.entries[0].parent && plan.entries[1].parent == 0 && plan.entries[1].depth == 1, "cyclic attribution must break only its cyclic edge without losing cards");
  tasks.front().coordinator = coordinatorReference(2, 2);
  require(workspaces.apply({.revision = 2, .entries = projects, .worktrees = tasks}), "stale coordinator references remain representable");
  Order::write(sources, 0, plan);
  require(!plan.entries[0].parent, "an explicit stale reference must not fall back to a coincident pane id");
  Agent agent{memory};
  agent.final_message = "\n \t\n  Final answer\t\nother";
  require(agent.finalLine() == "Final answer", "task summaries must use the original first nonempty line");
}

void crossMachineAliasesResolveDeterministically() {
  SystemAllocator memory;
  WorkspaceReplica parent_workspaces{memory};
  WorkspaceReplica child_workspaces{memory};
  AgentReplica parents{memory};
  AgentReplica children{memory};
  const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
  std::array rows{worktreeEntry()};
  rows.front().coordinator = coordinatorReference(1);
  const std::array parent_reports{agentSnapshotEntry()};
  auto report = parent_reports.front();
  // Other machines contribute only the agents that wait on the person.
  report.status = AgentStatus::blocked;
  report.session_id = coordinatorReference(1).session_id;
  const std::array identified_parents{report};
  report.pane_id = 2;
  report.work_tree = task_worktree_id;
  report.final_message = "\n A retained answer\n";
  const std::array child_reports{report};
  parent_workspaces.apply({.revision = 1, .entries = projects});
  child_workspaces.apply({.revision = 1, .entries = projects, .worktrees = rows});
  parents.apply({.revision = 1, .entries = identified_parents}, 0);
  children.apply({.revision = 1, .entries = child_reports}, 0);
  require(children.entries().front().finalLine() == "A retained answer", "runtime task summaries must retain their owned final message");
  using Order = ActivityOrder<SystemAllocator>;
  const std::array sources{
      Order::Source{.slot = 0, .agents = parents.entries(), .workspaces = parent_workspaces},
      Order::Source{.slot = 1, .agents = parents.entries(), .workspaces = parent_workspaces},
      Order::Source{.slot = 2, .agents = children.entries(), .workspaces = child_workspaces},
  };
  Order::Plan plan;
  Order::write(sources, 0, plan);
  require(plan.count == 3 && plan.entries[1].source == 2 && plan.entries[1].parent == 0 && plan.entries[2].source == 1, "aliased runtime identities must choose the first exact coordinator without hiding either alias");
}

void otherMachinesListOnlyAgentsThatWait() {
  SystemAllocator memory;
  WorkspaceReplica workspaces{memory};
  AgentReplica agents{memory};
  const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
  std::array rows{worktreeEntry()};
  rows.front().worktree = command_worktree_id;
  rows.front().workspace.reset();
  rows.front().command_state = CommandState::running;
  rows.front().command_label = "test";
  require(workspaces.apply({.revision = 1, .entries = projects, .worktrees = rows}), "workspaces must commit");
  std::array reports{agentSnapshotEntry(), agentSnapshotEntry(), agentSnapshotEntry()};
  reports[0].status = AgentStatus::working;
  reports[1].pane_id = 2;
  reports[1].status = AgentStatus::blocked;
  reports[2].pane_id = 3;
  reports[2].status = AgentStatus::failed;
  require(agents.apply({.revision = 1, .entries = reports}, 0), "agents must commit");
  using Order = ActivityOrder<SystemAllocator>;
  const std::array sources{
      Order::Source{.slot = 0, .agents = agents.entries(), .workspaces = workspaces},
      Order::Source{.slot = 1, .agents = agents.entries(), .workspaces = workspaces},
  };
  Order::Plan plan;
  Order::write(sources, 0, plan);
  std::size_t active = 0;
  std::size_t other = 0;
  for (const auto &entry : plan.view()) {
    if (entry.source == 0) {
      ++active;
      continue;
    }

    ++other;
    require(entry.agent && AgentOrder::attention(agents.entries()[*entry.agent].status) == AgentOrder::Attention::needs_input, "another machine lists only agents that wait on the person");
  }

  require(active == 4 && other == 2, "the active machine keeps every agent and command; another keeps its blocked and failed agents");
}

void commandNavigationUsesTheCurrentWorkspace() {
  SystemAllocator memory;
  Transport transport;
  Session session{memory, transport};
  std::array rows{worktreeEntry()};
  const std::array entries{WorkspaceListEntry{.workspace = 2, .name = "task", .path = "/project/worktree"}};
  deliver(session, WorkspaceList{.revision = 1, .entries = entries, .worktrees = rows});
  require(!session.openWorktree(task_worktree_id), "offline metadata must not navigate to a retired runtime");
  session.connected(1);
  require(!session.openWorktree(task_worktree_id), "a new connection must wait for refreshed workspace metadata");
  deliver(session, WorkspaceList{.revision = 1, .entries = entries, .worktrees = rows});
  require(session.openWorktree(task_worktree_id), "tracked command navigation must select its workspace");
  const auto request = transport.last<OpenPane>();
  require(request.target.kind == PaneTarget::Kind::workspace && request.target.id == 2 && !request.launch, "command navigation must open the materialized workspace without launching another command");
  deliver(session, RequestFailed{.request_id = request.request_id, .code = FailureCode::permission_denied, .message = "Workspace access was denied"});
  require(!session.requestsPending(), "the detached-worktree check must not be masked by an in-flight navigation request");
  rows.front().workspace.reset();
  deliver(session, WorkspaceList{.revision = 2, .entries = entries, .worktrees = rows});
  const auto requests = transport.sent.size();
  require(!session.openWorktree(task_worktree_id) && transport.sent.size() == requests, "a detached worktree must not reuse its previous workspace");
}

}

int main() try {
  workspaceMetadataAndRevisions();
  pathPoolAndAllocationFailure();
  activityNestsTasksAndCommands();
  exactReferencesAndCycles();
  crossMachineAliasesResolveDeterministically();
  otherMachinesListOnlyAgentsThatWait();
  commandNavigationUsesTheCurrentWorkspace();
  std::cout << "gui-activity: passed\n";

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
