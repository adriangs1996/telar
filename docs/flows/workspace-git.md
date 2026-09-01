# Workspace git status

Every workspace row can show its git branch and whether the tree is dirty.
Probing lives entirely on the observation path; rendering and input never
touch the filesystem or a subprocess.

## End-to-end path

```text
agent maintenance tick (1 s)
        |
GitObserver.tick: one stalest workspace, ≥ 5 s since its last probe,
                  at most one probe in flight runtime-wide
        |
select.concurrent(.git_status, probe)   -- worker thread
        |
read <path>/.git/HEAD  (a linked worktree's gitfile is followed)
git -C <path> status --porcelain --no-renames   (2 s timeout, 64 KiB cap)
        |
Event.git_status -> Workspace.applyGitStatus (bounded branch copy, change
                    detection) -> recordListChange on change
        |
schema.workspace_list entries now carry `branch` and `dirty`
        |
client workspace_list.Snapshot -> top bar rows render " name ⎇branch* "
```

## Ownership and bounds

The workspace aggregate owns the observed branch (64 bytes), the dirty flag
and its probe bookkeeping. A missing repository stores an empty branch, so a
directory that stops being a repo clears its badge. Probe failures leave the
previous projection and simply retry after the interval.

`parseHead` resolves `refs/heads/*` to the branch name, any other ref to its
full name and a detached head to its short hash, without running git; the
subprocess is only consulted for cleanliness.

## Proof

- `src/backend/runtime/application/git_status.zig` proves HEAD parsing.
- `src/backend/workspace/workspace.zig` proves bounded storage and change
  detection.
- `src/core/schema_contract_test.zig` pins the extended workspace list bytes.
