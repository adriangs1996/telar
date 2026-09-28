# Worktree git probe

Each tracked worktree carries how much it changed against its base: lines
added and removed, files touched, commits ahead and whether it has local
changes. The runtime measures it on a worker so the maintenance tick, the
interactive path and the frame budget never wait on Git.

## End-to-end path

```text
maintenance tick
        |
worktree_git.start -> reserve: the stalest due row, one probe in flight
        |
WorktreeProbeJob on the observation pool
        |  stat the checkout directory     (missing -> not present)
        |  gitstatus.probe.run             (branch from HEAD, git status -> dirty)
        |  gitstatus.base_distance.run     (merge-base with the base,
        |                                   diff --shortstat, rev-list --count)
        |
event .worktree_git -> worktree_git.finish -> commit
        |  present? no -> state = gone
        |  pending changes seen once, now none -> state = integrated
        |
Delivery: workspace_list{worktrees} when a visible value changed
```

## Budgets

A row running a command is due every `active_interval_ms` (5 s), a quiet one
every `idle_interval_ms` (30 s). After `max_failures` (2) failed measurements
in a row it drops to the idle interval until one succeeds. Only one probe is
in flight, so a slow repository delays its own numbers and nothing else.

`integrated` means the worktree once had changes and now has none against
its base: its branch was merged or its work reverted. `gone` means the
checkout directory disappeared. Both are shown dimmed; neither removes the
row, which only `telar worktree remove` or the `WorktreeRemove` hook does.

## Proof

`gitstatus` linked-worktree and base-distance tests, and the Worktrees table
tests.
