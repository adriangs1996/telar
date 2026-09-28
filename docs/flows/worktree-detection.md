# Worktree detection

Not every worktree goes through `telar worktree create`. Someone runs `git
worktree add` by hand, or an agent ignores the skill, then works there. The
runtime notices it from two sources and tracks it with origin `external`, so
it gets a diffstat, a state and a place in `worktree list` like any other.

## End-to-end path

```text
a pane's directory changes (history observer or process cwd)
        |
maintenance tick, or the previous detection finishing
        |
worktree_detection.start -> reserve: the first pane whose cwd revision
        |                   differs from panes.worktree_checked_cwd;
        |                   skips exited panes, relative paths and
        |                   directories inside a tracked worktree
        |
worker: gitstatus.linked_worktree.find   (reads .git files, no Git process)
        |
event .worktree_detected -> worktree_detection.finish
        |  pane gone or moved since (cwd revision) -> dropped; its new
        |  directory is already pending
        |  Worktrees.register {origin = external, source = the pane's
        |                      project, branch from the linked HEAD}
        |
Delivery: workspace_list{worktrees}; checkpoint noted
```

```text
Claude Code hook (PreToolUse, PostToolUse, Stop, ..., CwdChanged)
        |
telar hook claude -> hook_progress.map
        |  directory: `new_cwd` on CwdChanged, else `cwd`
        |  gitstatus.linked_worktree.find -> work_tree_path, work_tree_branch
        |
schema.report_agent_progress -> agent_hooks.receiveProgress
        |  a tracked checkout containing it, else register external,
        |  created_by = the agent's pane
        |
agents.work_tree = that worktree (task card)
```

## Rules

- The pane's own workspace is the source, through `Worktrees.sourceFor`, so
  a worktree found inside another worktree's tabs hangs from that one's
  project. The runtime does not know which workspace holds the same
  repository, so a pane in project A that moves into a worktree of project B
  hangs it from A.
- A branch the runtime cannot hold whole (over 200 bytes, or not printable
  UTF-8) names no worktree: it is not tracked rather than tracked under a cut
  name that `telar worktree` and `worktree:` would never match.
- Detection from a pane records no `created_by` and links no agent: only an
  agent's own hook sets `agents.work_tree`, so an agent without hooks in an
  external worktree draws its ordinary card, not a task card.
- Claude Code's `CwdChanged` names the directory it left in `cwd` and the one
  it entered in `new_cwd` (checked against Claude Code 2.1.283).

## Budgets

One detection is in flight. Reserving one walks the pane table (at most
`PaneStore.capacity` rows) comparing a revision, on the one-second tick or
when a detection finishes; an idle pane costs that comparison and nothing
else. The worker stats at most 64 ancestors, then reads the `.git` file and
the linked HEAD; it never runs Git and never touches runtime state.

## Proof

`src/backend/runtime/worktree_detection.zig`: a shell moving into a linked
worktree gets it tracked as external under its project, a move within it
starts no detection, a pane that moved while its directory was read is not
tracked from the old one, and a main checkout is no worktree.
`src/cli/hook_progress.zig`: `CwdChanged` resolves `new_cwd`.
`lib/gitstatus/linked_worktree.zig`: the linked worktree and the main
checkout's branch from files.
