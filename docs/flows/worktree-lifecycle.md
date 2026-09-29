# Worktree lifecycle

A worktree is a Git linked worktree the runtime tracks as a place where work
happens. `telar worktree` creates, runs in, opens, reviews and removes them;
agents reach the same commands through the `telar` and `telar-coordinator`
skills, and Claude Code's own worktrees arrive through its `WorktreeCreate`
hook. Worktrees nobody created through telar are found by
[worktree detection](worktree-detection.md). Git itself only ever runs in the
CLI process or on an observation worker, never on the interactive path.

## End-to-end path

```text
telar worktree create fix-tabs --title "Order tabs by use" -- claude "…"
        |
WorktreeOptions.parse     create and fetch: a branch Git accepts, at most
        |                 200 bytes (core.max_git_branch_bytes)
cli.worktree.create
        |  worktree_git.mainRoot (git rev-parse --git-common-dir)
        |  worktree_git.deriveDirectory -> <repo>-worktrees/<branch>
        |  base: --from, else the main checkout's branch; one the runtime
        |        cannot record whole, or a full Worktrees table, is refused
        |        before Git runs
        |  worktree_git.add (git worktree add -b <branch> <dir> <base>)
        |
schema.register_worktree{source, created_by, path, branch, base, title, brief}
        |
client_request.receive (control) -> worktree_lifecycle.register
        |  Worktrees.register (slotOfPath: the same path answers the same id;
        |                      core.validateWorktreeText, as the wire does)
        |
schema.worktree_registered{worktree}
        |
schema.launch_worktree{worktree, label, argv, cwd, size}
        |  argv = $SHELL -l -i -c 'exec "$0" "$@"' COMMAND... (see below)
        |
worktree_lifecycle.launch
        |  first launch: a child workspace named by the title or branch, bound
        |  to the row; later ones: a new tab in that workspace
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
        |  asks schema.read_pane every 250 ms until the reply carries an
        |  exit code; the encoder serves a finished pane from ExitedPanes
        |
CLI prints the output and exits with the command's code
```

```text
telar worktree remove fix-tabs [--force] [--delete-branch]
        |
worktree_git.hasChanges (git status --porcelain) -> refuse while the
        |  checkout has uncommitted or untracked files, unless --force;
        |  commits ahead are not checked: the branch keeps them
        |  (--force asks on a TTY)
worktree_git.branchMerged -> with --delete-branch, whether git branch -d
        |  would delete it: every commit in its upstream, or in HEAD without
        |  one, asked of Git run as gitstatus.untrusted_git. Merged, nobody
        |  is asked; otherwise --delete-branch asks on a TTY too
schema.forget_worktree -> worktree_lifecycle.forget
        |  closes the child workspace's panes, drops the row
worktree_git.remove, worktree_git.deleteBranch (git branch -d for a merged
        |  branch; -D for one a person agreed to delete)
```

## The command's environment

A worktree's command sees what a shell in one of its panes sees. The CLI
runs it through the user's login shell (`SHELL`, else the account's),
interactive so the rc files where PATH additions live are read
(`pty.login_shell.wrap`):

| Shell (base name) | argv |
| --- | --- |
| `bash`, `zsh`, `ksh` | `$SHELL -l -i -c 'exec -- "$0" "$@"' ARGV...` |
| `sh`, `dash` | `$SHELL -l -i -c 'exec "$0" "$@"' ARGV...` |
| `fish` | `$SHELL -l -i -c 'exec $argv' ARGV...` |
| any other (`tcsh`, `nu`) | `ARGV...` as given, in the runtime's environment |

The arguments are the shell's positional parameters, never shell code, and
the shell execs the command, so its exit status is the pane's and reaches
`exec --wait`. A program the rc files do not find exits 127 with the
shell's message in the pane. The worktree row names the command, not the
shell (`pty.login_shell.program`), and a restored pane relaunches through
the same shell. `--` keeps bash, zsh and ksh from reading a program named
like `-w` as an option of `exec`; dash would take `--` for the program, so
`sh`, which is dash on many Linux systems, goes without, and there, as in
fish, a program whose name starts with `-` cannot be started this way.

What cannot be avoided:

- Anything the rc files print before the command starts is in the pane,
  so `exec --wait` returns it above the command's output.
- An rc file that waits for input (a prompt, a plugin manager's question)
  holds the command until someone answers in the pane, and one that
  execs another program (`exec tmux`) replaces the shell before it runs
  the command. Either way `exec --wait` ends with its timeout.
- bash as a login shell reads `.bash_profile` (or `.profile`), which
  usually sources `.bashrc`.
- `worktree create` without a command starts the plain `$SHELL`, as a new
  pane does.

A launch the runtime cannot start fails with `spawn_failed` and a reason
from `pane_launch.spawnFailure`: the program is not on the runtime's PATH,
is not executable, or its directory cannot be entered. The CLI keeps the
runtime's words (`Session.failure_reason`) and prints them instead of the
error's kind.

## Naming a worktree

`exec`, `open`, `diff` and `remove` take a reference: the worktree's exact
branch, else a case-insensitive title that only one worktree has. Two projects
may use the same branch name; then the branch names neither and the title
has to (`AmbiguousWorktree`). `worktree:<branch or title>` names the agent in
a worktree the same way. `create` and `fetch` take a branch, because Git
makes or moves it.

## Ownership

The runtime owns the `Worktrees` table (`src/backend/workspace/Worktrees.zig`):
path, branch, base, origin, source workspace, creator pane, title, brief,
the machine that dispatched it (`dispatched_from`, see
[Worktree dispatch](worktree-dispatch.md)), state, diffstat and the last
command. Every text column follows `core.validateWorktreeText`, the rule the
wire applies, so a row the runtime accepts always encodes into every client's
workspace list. Its tabs belong to an ordinary child
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
`untracked`, and `findOrAdopt` registers it on its first `exec` or `diff`.
`open` and `remove` only act on tracked worktrees.

`telar worktree open` needs a worktree that already has a workspace (something
was launched there). It asks the runtime which UI client was used last (or
the one named by `--client`) and sends it a `workspace_select` client command
for that workspace; the CLI never changes focus of the pane it runs in.

## Forgetting a gone worktree

A row whose checkout disappeared turns `gone` and stays listed. The command
palette's "Forget gone worktrees" (`forget-gone-worktrees`) sends a
`forget_worktree` for every gone row the client lists whose tabs are all
closed (`src/model/workspace/worktree_lifecycle.zig`); there is nothing left
on disk to remove. Forgetting closes a worktree's tabs, so a gone row with a
tab still open, such as a shell left in the deleted directory, waits for the
user to close it. `telar worktree remove BRANCH` forgets one row the same way.
Plugins cannot trigger it.

## Persistence

`session_checkpoint` writes one `WorktreeRecord` per row (record kind
`worktree`, since checkpoint version 6; version 7 adds `dispatched_from`),
checked by `checkpoint.validateWorktree` with the same text rule. A record
that fails it is skipped (`Reader.skipped_worktrees`) rather than
quarantining the whole checkpoint with its workspaces and panes. Restore
rebuilds rows before workspaces, then `releaseMissingWorkspaces` unbinds rows
whose child workspace did not come back. See
[Session checkpoint](session-checkpoint.md).

## Claude Code hooks

`telar integration install claude` installs `WorktreeCreate` and `WorktreeRemove`
without the in-pane guard, and `CwdChanged` among the lifecycle hooks.
`hook_worktree.create` derives the branch from the hook's `name`, creates the
checkout where `telar worktree create` would, registers it when the hook runs
inside a telar pane, and prints the path Claude Code must use.
`hook_worktree.remove` forgets the row and removes the checkout without
`--force`, so one with changes stays for review.

## Proof

- `src/backend/workspace/Worktrees.zig`: registration, containment, command
  and workspace links, refused text.
- `src/backend/runtime/tests/worktree_lifecycle_test.zig`: registration once,
  launches that build the workspace and add tabs, an unknown worktree or
  source, forgetting a worktree and its workspace.
- `src/backend/runtime/instance.zig`: a restart restores every worktree field
  and unbinds a workspace whose panes did not come back.
- `src/backend/persistence/checkpoint.zig`: the record codec and text rule.
- `src/cli/arguments/WorktreeOptions.zig`, `src/cli/WorktreeCatalog.zig`:
  branch bound, references by title and ambiguous branches.
- `src/model/workspace/worktree_lifecycle.zig`: only gone rows are forgotten.
- Porcelain parsing, branch naming and the schema corpus.
