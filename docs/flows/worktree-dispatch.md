# Worktree dispatch

`telar worktree create BRANCH --machine LABEL` starts a worktree on another
machine from this one; `telar worktree fetch BRANCH --machine LABEL` brings
its branch back. Work never moves between machines; commits do, over Git on
telar's managed SSH connection, and every Git transfer starts on the machine
that dispatches, so no machine needs SSH back to it.

## End-to-end path

```text
telar worktree create fix-tabs --machine box --from HEAD --title "Fix tabs" -- claude "…"
        |
WorktreeOptions.parse                 --machine only on create and fetch;
        |                             --directory refused beside it
worktree.execute
        |  machine_dispatch.resolve   a saved profile, else the local label
        |  local label -> the ordinary create, here
        |
worktree_dispatch.create              no local runtime is contacted
        |  worktree_git.mainRoot       the repository of the current directory
        |  worktree_git.originIdentity git config remote.origin.url
        |                              -> repository_identity.normalize
        |
        |  repository_prepare.prepare  source-mediated Git bundle, runtime-owned receiver
        |                              open/catalog/history discovery, existing clone reuse
        |                              missing clone staged, verified and published atomically
        |                              multiple clones require --workspace PATH|ID
        |                              see repository-preparation.md
        |  source: the local branch BRANCH if it exists, else --from, else HEAD
        |  worktree_git.push           git push -- ssh://box/<path> <commit>:refs/heads/fix-tabs
        |                              GIT_SSH_COMMAND = SshOptions.gitCommand
        |
        |  machine_dispatch.forward
        v
telar worktree create fix-tabs --workspace <path> --dispatched-from laptop
      --title "Fix tabs" -- claude "…"                          (on box)
        |  the ordinary create: worktree_git.add checks out the branch it
        |  just received; RegisterWorktree carries dispatched_from
        v
box's Worktrees row: dispatched_from = "laptop"; stdout and exit status return
```

```text
telar worktree fetch fix-tabs --machine box
        |
worktree_dispatch.fetch
        |  resolve on box using catalog, history and managed path
        |  worktree_git.fetch   git fetch --no-tags -- ssh://box/<path>
        |                         +refs/heads/fix-tabs:refs/remotes/box/fix-tabs
        v
"fetched fix-tabs from box into refs/remotes/box/fix-tabs at <commit>"
```

Review and removal run where the worktree is, through
[machine dispatch](machine-dispatch.md): `telar --machine box worktree diff
fix-tabs`, `telar --machine box worktree remove fix-tabs`.

## Repository identity

`src/cli/repository_identity.zig` reduces an `origin` URL to `host/path`:
the user, scheme-default ports, `.git` and slashes go; nondefault ports remain, the host is lowercased. The SSH,
HTTPS and scp-like forms of one project agree. A local path or `file://`
origin names nothing another machine has and is refused. The identity finds
a clone; it never decides where work runs.

## Rules

- A push never forces. A branch that exists on the other machine with other
  history rejects the push and nothing is created there.
- Only commits travel. Uncommitted files are counted, reported on stderr, and
  stay.
- Telar prepares a missing clone through committed-history transfer; existing
  catalog and history paths find closed clones. Explicit `--workspace PATH|ID`
  selects an existing matching clone. See [repository preparation](repository-preparation.md).
- Declared `.telar/setup.json` requires `--setup`. Setup runs as an observable
  execution before agent launch; failure retains the worktree and refuses launch.
- `git` runs with `GIT_SSH_COMMAND` set to the managed SSH options (batch
  mode, keepalives, no agent forwarding, the control master in telar's
  owner-only runtime directory), every word single-quoted for `sh`, and
  `GIT_TERMINAL_PROMPT=0`. A destination with `:`, `/` or brackets is refused
  because Git would parse it as part of the URL.
- `dispatched_from` is attribution only: a label of at most 32 bytes that
  the runtime stores, lists and checkpoints (checkpoint version 7). A
  runtime still knows nothing about other machines.
- `fetch` needs another machine; the local label is refused. The
  remote-tracking ref is updated with `+`, since it only mirrors the other
  machine.

## Validation

- `src/cli/repository_identity.zig`: the transports agree; local origins
  and oversized identities are refused.
- `src/cli/arguments/WorktreeOptions.zig`: `--machine`, `fetch`, `resolve`,
  `--dispatched-from` and their refusals.
- `src/cli/worktree_dispatch.zig`: the forwarded `create` argv.
- `src/client/machines/SshOptions.zig`: the quoted `GIT_SSH_COMMAND`.
- `src/backend/persistence/checkpoint.zig`: version 7 keeps
  `dispatched_from`; version 6 still reads.
- Schema corpus: `register_worktree` and `workspace_list` carry it.
- Against the Linux SSH box (`tools/local-docker`): create with a dirty
  checkout, the recorded start commit as base, a commit made there and
  fetched back, a diverged branch refused with nothing created, an
  ambiguous identity settled by `--workspace`, a missing clone, a local
  origin, unknown and local labels for fetch, the local label creating
  here, and `dispatched_from` surviving a runtime restart.

The isolated acceptance test is `python3 tools/test_fleet_operations.py`; it uses
fake SSH and disposable local runtimes, without accessing the real fleet.
