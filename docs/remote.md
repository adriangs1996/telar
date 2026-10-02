# Remote machines

A local Telar window can connect to a runtime on an SSH host. The shell,
files and agents stay on that host. Closing the window or losing the connection
leaves them running there while the host and runtime remain alive.

This guide assumes `telar` is [on your local PATH](usage.md#put-telar-on-your-path).
Replace `dev@box` with your SSH destination and `box` with a saved label.

## Prepare the host

Telar needs noninteractive SSH authentication and matching local/remote builds.
First connect normally to verify the host key and authentication, then check
that batch mode works:

```sh
ssh dev@box
# Exit the remote shell, then run locally:
ssh -o BatchMode=yes dev@box true
```

If batch mode fails, configure SSH keys or an authentication agent before
continuing. Do not disable host-key verification to work around the failure.

Build the same Telar commit on the host. A Linux server needs only Zig and its
C development environment when building without a GUI:

```sh
zig build -Dgui=false -Doptimize=ReleaseFast
```

Put that executable on the remote noninteractive SSH PATH, then check from
your local shell:

```sh
ssh -o BatchMode=yes dev@box 'command -v telar && telar --version'
telar --version
```

Development builds can share the version `0.0.0` while speaking different
protocols. Use the same source commit, not just the same version string.
The connection rejects an incompatible protocol.

## Open and reconnect

From your local machine:

```sh
telar gui --remote dev@box
```

The window connects and shows the remote machine first. Telar starts the
remote runtime if needed. Traffic uses SSH; no public Telar TCP listener is
required. The window retries a dropped connection. Reopen the same command to
return after closing it.

The local window's appearance follows its client configuration. Runtime
settings such as history and proxy belong to the remote runtime. Changing
local runtime settings does not reconfigure a running remote server.

## Save a machine

```sh
telar machine add box dev@box --check
telar machine list --json
telar gui --machine box
```

The label is how you address that host afterwards. `--check` verifies the
connection before saving it and may start its runtime. Saved, enabled machines
are available in your windows. To stop automatically connecting to a saved
machine, or undo that choice:

```sh
telar machine disable box
telar machine enable box
```

`telar machine remove box` removes the saved profile. It does not stop the
remote runtime or delete the remote files.

## Run a command on a saved machine

Prefix each remote CLI command explicitly:

```sh
telar --machine box agent list --json
telar --machine box workspace list --json
telar --machine box exec --no-stdin -- pwd
```

The last command runs without a terminal and defaults to that account's HOME.
Use `--cwd /absolute/remote/path` for a different working directory. A shell
expression needs an explicit shell, for example `exec -- sh -c '…'`.

Machine selection is not inherited by the next command. IDs returned by the
host belong to that host; a local pane or workspace ID cannot select the same
thing remotely. A remote failure does not fall back to local execution.

## Set up a host using a local build

For development builds, `machine setup` can upload an executable you already
built **for the destination OS and architecture**. First save the machine
without `--check` if Telar is not yet installed there, then:

```sh
telar machine add box dev@box
telar machine setup box --binary /absolute/path/to/remote-build/telar --skip agents,config,login
```

Use this as an alternative to manual installation above; do not add a second
profile for a machine already saved. Setup installs under the remote account's
home and remembers the executable path, so discovery no longer depends on its
SSH PATH. It still needs working SSH and the prerequisites reported by setup.

The skip flags leave agent installation, configuration copying and provider
login to you. Without those flags, setup also attempts those steps and may
overwrite synchronized configuration on the destination. A running incompatible
runtime requires an explicit restart decision. Save its work first.

There are no published releases yet, so use `--binary` for this workflow rather
than expecting setup to download a release. The [setup implementation guide](flows/machine-setup.md)
explains the full synchronization and login behavior.

## Remote worktrees

From the local Git project, with committed inputs and an authenticated agent
installed on the host:

```sh
telar worktree create fix-tests --machine box --title "Fix tests remotely" --json -- claude
```

Telar prepares the repository remotely and launches the task there. Only
committed history travels. A declared `.telar/setup.json` recipe requires
explicit `--setup` authorization; inspect that recipe before running it.
If setup fails, no agent starts. Inspect the retained worktree and logs before
retrying so you do not create a duplicate task.

Inspect on the destination; fetch back from your local project:

```sh
telar --machine box worktree list --json
telar --machine box worktree diff fix-tests --stat
telar worktree fetch fix-tests --machine box --json
```

Fetch creates `refs/remotes/box/fix-tests` locally. Review it with
`git log HEAD..refs/remotes/box/fix-tests` and
`git diff HEAD...refs/remotes/box/fix-tests`; fetch does not merge it into your
current branch. See [working with agents](agents.md) for task control.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| SSH asks for a password or rejects the host | Make the batch-mode check above pass first. |
| Remote `telar` is not found | Check the noninteractive PATH, or use setup with a destination-compatible `--binary`. |
| Protocol/schema mismatch | Use matching builds; save running work before replacing/restarting the old runtime. |
| Unknown pane, workspace or worktree | Include `--machine box` and discover the destination's IDs again. |
| Setup cannot find a release | This checkout is unreleased; provide `--binary`. |
| Remote task lacks local edits | Commit required inputs before transfer; uncommitted files stay local. |

`telar machine check box --json` checks discovery and protocol compatibility.
It can start the remote runtime. For connection ownership and SSH details, see
[remote attach](flows/remote-attach.md).
