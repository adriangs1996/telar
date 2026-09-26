# Task cards

The sidebar shows the fleet: agents grouped by project, the agents of a
project's main checkout first, and below them one task card per agent that
works in one of its worktrees. A task card names the task, not the project
the group already names.

## End-to-end path

```text
schema.agent_snapshot{work_tree, final_message, plan_*}   schema.workspace_list{worktrees}
        |                                                   |
agent_snapshot.applyAgentSnapshot                   workspace_list_snapshot.apply
        |  Agent.work_tree, final_message, plan         |  WorktreeRow per entry,
        |                                               |  projects ordered first
        +---------------------+-------------------------+
                              |
fleet_order.order(FleetSources) -> FleetEntry{index, card, first_in_project}
        |  group: the project that owns the agent's workspace or worktree
        |  inside a group: main-checkout agents, then full task cards,
        |  then compact ones, each part in the shared attention order
        |  card: agent | task_full | task_compact
        |
GUI SidebarState.observe -> Sidebar.drawList -> AgentCard | TaskCard
TUI widgets/sidebar.refreshFleet -> drawAgentLine | drawTaskLine
```

## Density

A task is a compact single line (status, title, branch handle, age) while it
works quietly or rests reviewed. It is a full three-row card while it is
blocked, failed or done, and while it is the focused agent: the branch
handle, diffstat, commits ahead and last command beside the status; the task
title; what happens now (the question it asks, the plan step with a bar, or
the first line of its final answer).

The fleet order is recomputed only when the agent snapshot revision, the
workspace list revision or the focused agent changes. It writes into a fixed
array of `max_agent_snapshot_entries`; drawing allocates nothing.

## Projects

The workspace list shows projects only; a project's worktrees appear as a
summary `⎇ N · ◌ n ✓ n` (worktrees, tasks working, tasks finished). Inside a worktree the top
bar reads `project › ⎇ handle` in a distinct accent, and `leave-worktree`
(`prefix+b`) returns to the source workspace.

## Proof

Fleet order, snapshot mapping, sidebar card geometry and TUI sidebar tests.
