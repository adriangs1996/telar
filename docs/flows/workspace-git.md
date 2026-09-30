# Workspace git status

The runtime observes each workspace's git branch and whether the tree is dirty.
Probing lives entirely on the observation path; rendering and input never
touch the filesystem or a subprocess. The top bar deliberately renders only
workspace names and does not mark dirty workspaces.

## End-to-end path

```text
agent maintenance tick (1 s)
        |
workspace_git.start: one stalest workspace, ≥ 5 s since its last probe,
                  at most one probe in flight runtime-wide; each finish
                  starts the next due probe, so many workspaces still
                  refresh every 5 s instead of one a tick
        |
model.select.concurrent(.git_status, git_probe.probe)   -- worker thread
        |
read <path>/.git/HEAD  (a linked worktree's gitfile is followed)
git -C <path> status --porcelain --no-renames   (10 s timeout; any output
                                                 means dirty, however long)
        |
Event.git_status -> workspace_git.finish (reports a timeout as
                    gitstatus.status_timeout, bounded branch copy, change
                    detection) -> workspaces.advanceRevision on change
        |
schema.workspace_list entries carry `branch` and `dirty`
        |
client workspace_list_snapshot.apply -> model.workspace_list_snapshot
                    -> navigation metadata; top bar renders " name "
```

## Ownership and bounds

The runtime `Workspaces` table owns the observed branch (`git_branch`, at most
`core.max_git_branch_bytes`, 200 bytes), the dirty flag (`git_dirty`) and its
probe bookkeeping (`git_checked_at_ms`, `git_probe`). A missing repository stores an empty branch, so a
directory that stops being a repo clears its badge. Probe failures leave the
previous projection and simply retry after the interval. A status that runs
past `gitstatus.probe.status_timeout_ms` (10 s in all: one deadline for the
config read, the version check and the status) leaves the dirty flag
unknown and the completion carries the `gitstatus.status_timeout` limit.
`finish` reports it on the loop the first time in a row
(`Workspaces.git_timed_out`), so a monorepo that always takes longer is
named once, not every minute.
Standard error is read and dropped, so a repository that prints many
warnings still answers.

`git_probe.parseHead` resolves `refs/heads/*` to the branch name, any other ref to its
full name and a detached head to its short hash, without running git; the
subprocess is only consulted for cleanliness.

## Validation

- `src/backend/runtime/workspace_git.zig` proves probe reservation, stale
  results, bounded storage and change detection.
- `lib/gitstatus/probe.zig` proves `HEAD` resolution.
- `src/core/schema_contract_test.zig` pins the extended workspace list bytes.

## Worktrees from the CLI

`telar workspace create --worktree <branch>` runs `git rev-parse` and
`git worktree add` in the CLI process (creating the branch when it does not
exist), then sends the ordinary `create_workspace` request with the worktree
path as the launch cwd. The runtime treats it like any other workspace; the
observer above picks up its branch and dirty state on the next maintenance
tick. Branch names are validated at parse time so the git argv stays
positional. `src/cli/workspace.zig` owns the derivation and the git calls;
`src/cli/parser.zig` proves the validation.
