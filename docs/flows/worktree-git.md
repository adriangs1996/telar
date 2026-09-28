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
        |  gitstatus.probe.run             (branch from HEAD, git status -> dirty;
        |                                   a branch the row cannot hold whole
        |                                   keeps the recorded one)
        |  no base recorded? gitstatus.linked_worktree.mainBranch
        |                                  (the main checkout's branch, from files)
        |  gitstatus.base_distance.run     (merge-base with the base,
        |                                   diff --shortstat, rev-list --count)
        |
event .worktree_git -> worktree_git.finish -> commit
        |  present? no -> state = gone
        |  a base found for a row without one is kept, once, and checkpointed
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
row, which only `telar worktree remove`, the `WorktreeRemove` hook or the
palette's "Forget gone worktrees" does.

A worktree found by [detection](worktree-detection.md) or an agent hook has
no base when it is registered. Its first probe measures it against the
branch its repository's main checkout stands on, which is what `telar
worktree create` would have recorded, and the row keeps that base. A
detached main checkout gives no base, and the row stays unmeasured.

## A repository nobody vouched for

The probe runs Git in any checkout a shell entered, including one extracted
from a tarball, which passes `safe.directory` because the user owns it. Its
config can name programs that read-only commands run, so every Git child of
the workspace and worktree probes and of the path picker's index goes
through `gitstatus.untrusted_git`:

| Program the repository names | Turned off by |
| --- | --- |
| `core.fsmonitor` | `-c core.fsmonitor=false` |
| hooks, from the hooks directory or config (`hook.<name>.command` with `hook.<name>.event`) | `-c hook.<event>.enabled=false` for every event `githooks(5)` lists, `-c core.hooksPath=/dev/null`, `GIT_OPTIONAL_LOCKS=0` |
| filter drivers (`clean`, `process`) from `.gitattributes` or `.git/info/attributes`, including `[filter ""]` | `-c filter.<name>.clean=` (and `smudge`, `process`) for every driver the repository's own config defines, listed by `git config --show-scope`; more than 8, or a name `-c` cannot carry, and nothing runs |
| `diff.external`, a diff driver's `textconv` | `--no-ext-diff --no-textconv` |
| a partial clone's lazy fetch (`uploadpack`, `core.sshCommand`) | `GIT_NO_LAZY_FETCH=1`; with a Git older than 2.45, which ignores it, a repository that is a partial clone (`remote.*.promisor`, `remote.*.partialclonefilter` alone, `extensions.partialClone`) or names a `remote.*.uploadpack` of its own is not measured |
| submodules | `--ignore-submodules=all` |
| `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and every other `GIT_*` variable of the runtime's environment | removed from the child's environment |

Revisions end at `--`, so a file named after the merge base cannot turn a
revision into a path. Any failed step, `git status` included, leaves the row
unmeasured rather than measured as zero or clean: its numbers, its local
changes and its state stay as the last measurement left them, so a failure
never turns a row `integrated`. A workspace whose status failed keeps the
dirty mark it showed.

Filter drivers the user defines globally or system-wide, such as Git LFS,
stay on. A repository that defines its own LFS driver locally is compared
by raw content and may read as changed.

## Proof

`gitstatus/untrusted_test.zig` measures a planted repository whose config
names a program for each row above and fails if any of them ran (it does
with the options removed), runs `status` with only the hardened options so
Git writes the index and still no hook fires, plants files named after the
merge base, and sets `GIT_DIR` and `GIT_WORK_TREE` to another repository;
`path_index_build.zig` lists a repository with `core.fsmonitor` set; `gitstatus` linked-worktree and base-distance
tests; `worktree_probe.zig`
measures a hand-made worktree in a real repository against its main
checkout's branch; `worktree_git.zig` keeps a found base once and turns rows
`integrated` and `gone`; the Worktrees table tests.
