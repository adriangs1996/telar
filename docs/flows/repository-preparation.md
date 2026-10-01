# Repository preparation, setup and files

Run `telar repository prepare --machine box --from HEAD --json` in a source
clone. Remote `worktree create --machine box` calls this same flow automatically
before its existing non-force branch push and ordinary worktree creation.
Only the selected commit and reachable committed history travel. Dirty files are
reported and stay on the source. The source uses its existing provider access;
the destination never clones or fetches from the provider during preparation.

The dispatching CLI creates a temporary transfer ref, creates a bounded Git
bundle, and sends it over managed SSH to a runtime-owned `repository receive`
execution. The destination serializes one repository with an OS lock, receives
the exact advertised length, verifies the bundle and requested commit, and
checks object readiness. A new repository is initialized with no Git template,
checked out detached, and atomically renamed without replacing a destination.
The transfer ref and local temporary directory are removed on normal exit.
A source CLI killed by SIGKILL may leave its private temporary file/ref; no
background process scans and deletes arbitrary refs or temp directories.

Matching normalizes origin to lowercase host and case-sensitive path, strips
userinfo, trailing slashes and `.git`, and retains nondefault ports. Default
SSH/HTTPS/HTTP ports normalize away. Identity is a matching key, not a transport
URL. The separately stored origin preserves non-secret scheme, host, port, path
and SSH username. HTTP userinfo is stripped, query/fragment URLs are refused.
No Git configuration tree, key, token, credential store or forwarded SSH agent
travels. Hardened Git disables hooks, filters and lazy provider fetches. A
bundle exceeding 256 MiB is refused during bounded collection; no unbounded
bundle file is written. Preparation is observation work and can allocate this
bounded collection on the dispatching CLI. Other Git output is capped at 8 MiB.
Collectors drain excess output within the Git deadline and report dropped bytes
as a named limit error before parsing or transfer. Git operations have a 600 s deadline.

Discovery uses current runtime workspaces/worktrees, existing history session
paths (up to 4096 distinct paths), and the deterministic managed location:
`${XDG_DATA_HOME:-$HOME/.local/share}/telar/repositories/<SHA256(identity)>`.
Closed workspaces are discoverable through history. No second repository registry
is introduced. Several distinct matching clones require `--workspace PATH|ID`.
An explicit path must already match; it is not permission to overwrite unrelated
content. Existing clones receive objects/FETCH_HEAD, but their checkout, branches,
origin and user configuration are preserved. Branch publication remains a
non-force push and refuses divergence.

Managed paths are opened without symlink traversal and their parent must be
owned and not group/world writable. A sibling `<hash>.stage` is owned only when
its private `owner` marker exactly matches the identity. Under the repository
lock, a retry removes that owned stage and starts again; an unmarked or foreign
stage is refused. A transfer cut short by disconnect cannot publish. Atomic
publication is supported on macOS and Linux. It is not a disk durability
transaction across power failure. Existing user clones are never recursively
removed by preparation.

Shallow repositories, partial/promisor repositories, gitlink submodules and
committed `.gitattributes` declaring LFS are explicitly unsupported and refused.
Object connectivity is checked. This does not download LFS/submodule contents or
prepare package dependencies. Repository results say `repository_ready: true`
and `environment: "not_run"`; these are separate claims.

## Declared project setup

Commit `.telar/setup.json` in the project:

```json
{"version":1,"argv":["/bin/sh","scripts/setup.sh"]}
```

The file is at most 32 KiB, owned, regular and not a symlink or hard link. The
argv obeys execution bounds. No framework or install script is inferred. Run
`telar --machine box project setup --cwd /absolute/checkout --json` to authorize
one invocation, or pass `--setup` to `worktree create` to authorize its declaration.
A declared recipe without that flag refuses task launch. An absent recipe is
reported as `not_declared`, not a prepared dependency environment.

Setup is an execution with explicit cwd and EOF stdin. The CLI prints its ID,
streams logs on stderr and waits up to 600 s; `--detach` returns it immediately.
Use `exec status`, `output` and `cancel` with that ID. Every explicit invocation
repeats the recipe; there is no success cache. Recipes must tolerate retries
according to the project's policy. A setup failure, missing tool or missing
registry/service access leaves the registered worktree available for inspection
and refuses the agent launch. Provision access separately on that destination,
then explicitly retry `project setup`; after success use `worktree exec` to
start the task. Setup never transfers package tokens or manufactures logins.
Worktree create results include the setup execution ID and environment readiness.

## Files and an entire dispatch

`file put ABS_PATH --bytes N` streams stdin into a private temporary file,
checks its exact length, syncs it, then publishes without replacing any existing
path. `file get ABS_PATH` emits raw bytes. Both are capped at 128 MiB and require
owned regular files/directories; symlink traversal, devices, FIFOs and hardlinked
input files are refused. Canonical absolute paths are required (on macOS, use
`/private/tmp`, not the `/tmp` symlink). Transfer one requested artifact, not
credential/configuration trees. For a large result artifact use
`telar --machine box file get /absolute/artifact > local-artifact`: managed SSH
applies ordinary stream backpressure without exec's retained-output tail. The
read-only transfer itself can be interrupted; check its exit status before using
the local file. Wrapping get in exec makes it observable runtime-owned work but
then exec's retention/loss contract applies. EOF with a wrong length discards the temporary.
SIGKILL can leave an unreferenced `.telar-file-*` temporary, never a partial
published file; remove that known artifact after inspection if needed.

```sh
# Source: inspect/commit the task inputs first.
telar repository prepare --machine box --from HEAD --json
# Use the reported destination path; choose a new owned brief path.
telar --machine box exec -- telar file put /home/dev/task-brief.md --bytes 1234 < brief.md
telar worktree create fix-tabs --machine box --setup --title "Fix tabs" --json -- codex --no-daemon "Read /home/dev/task-brief.md; implement, test and commit."
telar --machine box agent wait worktree:fix-tabs --until finished --timeout 3600s --json
telar --machine box worktree diff fix-tabs --stat
telar worktree fetch fix-tabs --machine box --json
# Review refs/remotes/box/fix-tabs and integrate only when authorized.
# Remove only after the destination branch is safely merged, or with explicit
# authorization for the existing unmerged-work removal policy.
telar --machine box worktree remove fix-tabs --delete-branch
```

Replace `telar` inside exec with the configured destination executable path when
it is absent from PATH. Byte counts come from the actual local artifact; never
hardcode the example count. `worktree create` automatically prepares a missing
clone, so explicit preparation is useful for inspection but is not required.
The source may sleep after agent launch; the destination owns the task. Fetching
results requires the source again, not an always-on fleet hub.

The isolated fake-SSH acceptance script covers missing, reused, closed, ambiguous
and unrelated clones; concurrent and interrupted preparation; dirty input;
sanitized origin; branch divergence; setup failure/retry/cancel; brief transfer;
a safe simulated agent's commit; fetch and cleanup through public Telar commands.
