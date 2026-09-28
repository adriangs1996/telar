# Worktree lifecycle

A worktree is a Git linked worktree the runtime tracks as a place where work
happens. `telar worktree` creates, runs in, opens, reviews and removes them;
agents reach the same commands through the `telar` and `telar-coordinator`
skills, and Claude Code's own worktrees arrive through its `WorktreeCreate`
hook. Git itself only ever runs in the CLI process or on an observation
worker, never on the interactive path.

## End-to-end path

```text
telar worktree create fix-tabs --title "Order tabs by use" -- claude "…"
        |
cli.worktree.create
        |  worktree_git.mainRoot (git rev-parse --git-common-dir)
        |  worktree_git.deriveDirectory -> <repo>-worktrees/<branch>
        |  worktree_git.add (git worktree add -b <branch> <dir> <base>)
        |
schema.register_worktree{source, created_by, path, branch, base, title, brief}
        |
client_request.receive (control) -> worktree_lifecycle.register
        |  Worktrees.register (slotOfPath: the same path answers the same id)
        |
schema.worktree_registered{worktree}
        |
schema.launch_worktree{worktree, label, argv, cwd, size}
        |
worktree_lifecycle.launch
        |  first launch: a child workspace named by the handle, bound to the row
        |  later ones: a new tab in that workspace
        |  Worktrees.startCommand (label, running)
        |
schema.pane_opened -> Delivery: workspace_list{worktrees} to every client
```

```text
child exits -> pane_closure.collect
        |  ExitedPanes.keep (last 16 KiB of text, exit code; ring of 16)
        |  worktree_lifecycle.finishCommand -> command_state = exited, exit code
        |
telar worktree exec fix-tabs --wait -- zig build test
        |  polls the snapshot until the pane leaves it, then
schema.read_pane -> encoder serves ExitedPanes -> schema.pane_text{exit_code}
        |
CLI prints the output and exits with the command's code
```

```text
telar worktree remove fix-tabs [--force] [--delete-branch]
        |
worktree_git.hasChanges -> refuse while dirty or ahead unless --force
        |                  (--force and --delete-branch ask on a TTY)
schema.forget_worktree -> worktree_lifecycle.forget
        |  closes the child workspace's panes, drops the row
worktree_git.remove, worktree_git.deleteBranch
```

## Ownership

The runtime owns the `Worktrees` table (`src/backend/workspace/Worktrees.zig`):
path, branch, base, origin, source workspace, creator pane, title, brief,
the machine that dispatched it (`dispatched_from`, see
[Worktree dispatch](worktree-dispatch.md)), state, diffstat and the last
command. Its tabs belong to an ordinary child
workspace (`WorkspaceLocation.workspace`), so every tab, pane, layout and
navigation path works unchanged; the row names that workspace and
`Worktrees.slotOfWorkspace` answers the reverse question. When the child
workspace closes, `worktree_lifecycle.releaseWorkspace` unbinds it and the
next launch builds a new one.

Paths never cross into the UI. Clients receive a `WorktreeListEntry` per row
and show its handle (the branch without the `worktree-` prefix Claude Code
adds) and title.

`telar worktree list` merges `git worktree list --porcelain` with the
runtime's rows: an untracked checkout of the same repository is shown as
`untracked`, and `findOrAdopt` registers it on its first `exec` or `open`.

`telar worktree open` asks the runtime which UI client was used last (or the
one named by `--client`) and routes a `focus_pane` command to it; the CLI
never changes focus of the pane it runs in.

## Persistence

`session_checkpoint` writes one `WorktreeRecord` per row (record kind
`worktree`, since checkpoint version 6; version 7 adds `dispatched_from`). Restore rebuilds rows before workspaces, then
`releaseMissingWorkspaces` unbinds rows whose child workspace did not come
back. See [Session checkpoint](session-checkpoint.md).

## Claude Code hooks

`telar integration install claude` installs `WorktreeCreate` and `WorktreeRemove`
without the in-pane guard. `hook_worktree.create` derives the branch from the
hook's `name`, creates the checkout where `telar worktree create` would,
registers it when the hook runs inside a telar pane, and prints the path
Claude Code must use. `hook_worktree.remove` forgets the row and removes the
checkout without `--force`, so one with changes stays for review.

## Proof

Worktrees table, record codec, checkpoint restore, CLI argument, porcelain
parsing, branch naming and schema corpus tests.
