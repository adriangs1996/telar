# Task cards

The sidebar shows the fleet: agents grouped by project, and one task card
per agent that works in one of the project's worktrees. A task card hangs,
indented with a guide line, under the agent whose pane created its
worktree (`WorktreeListEntry.created_by`), while that agent lives. A task
card names the task, not the project the group already names.

## Who a task hangs under

Inside a project, each agent of the main checkout comes in attention
order, followed by the tasks it created. A task has no parent to show
when its creator's pane closed, when a plain shell created it, when its
creator is itself a task, or when the pane that created the worktree is
the one working in it (Claude Code's `WorktreeCreate` hook registers the
session that then moves into the worktree). Those tasks close the group,
full ones first, and are drawn flush with the agents, without indent or
guide line: indenting them would name a parent that does not exist. A
"Tasks" heading would say the same with one more row of chrome, so there
is none.

## End-to-end path

```text
schema.agent_snapshot{work_tree, final_message, plan_*}   schema.workspace_list{worktrees}
        |                                                   |
agent_snapshot.applyAgentSnapshot                   workspace_list_snapshot.apply
        |  Agent.work_tree, final_message, plan         |  WorktreeRow per entry,
        |                                               |  projects ordered first
        +---------------------+-------------------------+
                              |
fleet_order.order(FleetSources) -> FleetEntry{index, card, creator, first_in_project}
        |  group: the project that owns the agent's workspace or worktree
        |  creator: the main-checkout agent in the worktree's created_by pane
        |  inside a group: each main-checkout agent, then its tasks (full,
        |  then compact); then the tasks without a live creator; each part
        |  in the shared attention order
        |  card: agent | task_full | task_compact
        |
GUI SidebarState.observe -> Sidebar.drawList -> AgentCard | TaskCard
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
(`prefix+u`) returns to the source workspace.

## Proof

Fleet order (`src/client/agents/fleet_order.zig`: a task under its live
creator even when another agent of the project comes between them in
attention order; a closed creator, a hook-registered worktree and a
worktree without creator close the group), snapshot mapping and sidebar
card geometry tests.
