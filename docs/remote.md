# Remote machines

A local Telar window can connect to a runtime on another machine. The shell,
files and agents stay on that machine. Closing the window or losing the
connection leaves them running there while the machine and its runtime remain
alive.

Telar reaches the other machine itself: the account there runs a small
gateway, and this machine pairs with it once. No SSH server, key or account
setup is involved.

This guide assumes `telar` is [on your local PATH](usage.md#put-telar-on-your-path).
`box` stands for the label you give the machine.

## Install telar on the machine and start its gateway

Run one command on the machine, as the account whose terminals you want to
reach, with whatever access you already have to it (its console, a cloud
init script, a container's shell):

```sh
curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh -s -- --headless --serve
```

It installs telar under `~/.local/bin` without root, starts the gateway as a
service of that account and prints a pairing address:

```text
telar://box.example:8352#6fae526f…a9af.1a30130599b22d1637980d5f11e4a982
```

With telar already installed there, `telar server enable` does the same.
Both take `[HOST]:PORT` to listen somewhere other than port 8352 on every
address, and `--host NAME` when other machines reach this one by a name or
address that is not its host name:

```sh
telar server enable 9000 --host 203.0.113.7
```

The port must be reachable from your machine: open it in the firewall, or
publish it from the container. A machine behind NAT needs a forwarded port or
a VPN, as it would for any server.

There are no published releases yet. Until there are, build the same Telar
commit on the machine with the headless profile of the
[C++ build guide](build/cpp-modules.md#comandos-completos) and put `telar`,
`telar-runtime`, `telar-config-check` and `telar-gateway` together in one
directory:

```sh
tools/cpp bootstrap
tools/cpp configure release -B .dev/runtime-headless --headless -- -DTELAR_BUILD_GUI=OFF
tools/cpp build release -B .dev/runtime-headless -- --target telar telar-runtime telar-config-check telar-gateway
```

### What keeps the gateway running

`telar server enable` installs a service of the account, never of the system:

| System | Service | Starts |
| --- | --- | --- |
| Linux with systemd | `~/.config/systemd/user/telar-gateway.service` | at boot when the account lingers (`loginctl enable-linger`, which `enable` asks for and reports when the system refuses), otherwise at login |
| macOS | the launch agent `dev.telar.gateway` | while the account is logged in |
| anything else (a container, a login without a session) | none: the gateway is started for this boot | run `telar server listen` under the supervisor the machine uses |

`telar server disable` removes the service. The gateway's key and the machines
it admits survive it.

## Pair and save the machine

On your machine, with the address the other one printed:

```sh
telar machine add box 'telar://box.example:8352#6fae526f…a9af.1a30130599b22d1637980d5f11e4a982'
telar machine list --json
telar gui --machine box
```

The address has three parts. `box.example:8352` is where the gateway listens.
The 64 digits after `#` name the gateway's key: your machine refuses to talk
to anything that holds another key, so nobody between the two can stand in
for it. The 32 digits after the `.` are a pairing code that enrolls one
machine, once, within ten minutes; treat the whole address as a password until
it is used. What `machine add` saves is the address without the code.

From then on the two machines know each other by their keys. Nothing secret
is kept in `machines.json`; this machine's own key lives under
`$XDG_STATE_HOME/telar/gateway` (else `~/.local/state/telar/gateway`), readable
by your account alone.

Print another address on the machine whenever another computer needs one, and
see or end what it admits:

```sh
telar server pair
telar server access list
telar server access revoke ada-laptop
```

A revoked machine is refused from its next connection on.

## Open and reconnect

```sh
telar gui --machine box
```

The window connects and shows the machine first. Telar starts the runtime
there when none runs. The window retries a dropped connection. Reopen the same
command to return after closing it. Saved, enabled machines are available in
every window; to stop a window from connecting to one, or undo that choice:

```sh
telar machine disable box
telar machine enable box
```

`telar machine remove box` removes the saved profile. It does not stop the
runtime there, delete its files or revoke this machine at its gateway.

The local window's appearance follows its client configuration. Runtime
settings such as history and proxy belong to the runtime on the machine.
Changing local runtime settings does not reconfigure a running remote one.

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
machine belong to that machine; a local pane or workspace ID cannot select the
same thing remotely. A remote failure does not fall back to local execution.

## Reach a port of the machine from your browser

A development server on the machine prints a link such as
`http://localhost:3000`. That port is the machine's, not yours.

**Click the link in a pane of that machine.** Telar forwards the port and
opens the link in your browser. Port 3000 there becomes port 3000 here when it
is free; when it is taken, Telar picks another and opens the link with it. An
application that names its own port in redirects or OAuth callbacks needs the
same number on both sides, so free the port here in that case. A link in a
pane of your own machine opens as it always did.

**Share the ports of a command.** A command started with `--autoshare` shares
every port it opens with the machines connected to that one, without a click
and without a window:

```sh
telar --machine box exec --autoshare --cwd /srv/app -- pnpm dev
```

**See what is forwarded.**

```sh
telar --machine box ports
telar --machine box ports --json
```

Each line gives the port there, the address here, the connections open
through it, whether it was `asked` for (a click) or `shared` (`--autoshare`),
and what asked for it.

A forward ends by itself within a couple of seconds of the port closing on
the machine, when the command that shared it ends, and when the window or
command that asked for it goes away. Only loopback ports of the machine are
forwarded, only TCP, and they listen only on your loopback: any program on
your machine can use them, as with any forwarded port. `--autoshare` covers
the command's own process group; a child that starts a session of its own
leaves it.

## Set up a machine using a local build

Once a machine is paired, `machine setup` brings the rest in line with yours:
the telar build, the agents, their integration, configuration and logins.

```sh
telar machine setup box --skip agents,config,login
```

A new machine can be paired and set up in one step, with the address its
gateway printed:

```sh
telar machine setup 'telar://box.example:8352#…' --label box
```

For development builds, `--binary` uploads an executable you already built
**for the machine's OS and architecture**, with `telar-runtime`,
`telar-config-check` and `telar-gateway` beside it:

```sh
telar machine setup box --binary /absolute/path/to/remote-build/telar --skip agents,config,login
```

Setup installs under the remote account's home and remembers the executable
path. The skip flags leave agent installation, configuration copying and
provider login to you. Without those flags, setup also attempts those steps
and may overwrite synchronized configuration on the machine. A running
incompatible runtime requires an explicit restart decision. Save its work
first. A gateway that is already running keeps the build it started with until
`telar server enable` is run again there.

## Remote worktrees

From the local Git project, with committed inputs and an authenticated agent
installed on the machine:

```sh
telar worktree create fix-tests --machine box --title "Fix tests remotely" --json -- claude
```

Telar prepares the repository there and launches the task. Only committed
history travels, through the same gateway. A declared `.telar/setup.json`
recipe requires explicit `--setup` authorization; inspect that recipe before
running it. If setup fails, no agent starts. Inspect the retained worktree and
logs before retrying so you do not create a duplicate task.

Inspect on the machine; fetch back from your local project:

```sh
telar --machine box worktree list --json
telar --machine box worktree diff fix-tests --stat
telar worktree fetch fix-tests --machine box --json
```

Fetch creates `refs/remotes/box/fix-tests` locally. Review it with
`git log HEAD..refs/remotes/box/fix-tests` and
`git diff HEAD...refs/remotes/box/fix-tests`; fetch does not merge it into your
current branch. See [working with agents](agents.md) for task control.

## How the connection works

One program, `telar-gateway`, speaks to the other machine, in two roles. On
the machine you reach it listens on a TCP port. On yours it calls that port,
for a window, a command or a forwarded port.

- The connection is TLS 1.3 over TCP. Each side presents its own key; neither
  follows a certificate chain or trusts on first use. Your machine checks the
  gateway's key against the address it saved, and the gateway checks yours
  against the list of machines it paired. A machine that is not on the list is
  refused before it can send a request.
- The gateway runs as the account, without root, and serves that account
  alone. It carries bytes to the runtime's own socket, which still admits only
  processes of the same user: the runtime listens on nothing new.
- What a paired machine can do is what the account can do there: it opens
  shells. Pair only machines you would hand a shell to, and revoke the ones you
  no longer use.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `the gateway does not answer at its address` | The gateway runs there (`telar server enable`), the port is open and published, and the host in the address is how your machine reaches it (`telar server pair --host NAME`). |
| `this machine is not paired with that gateway` | It was revoked, or the gateway's state was reset. Print a new address there and run `telar machine setup ADDRESS --label box`. |
| `the gateway holds another key` | The address names a gateway that is no longer the one answering there. Do not work around it: confirm the machine, then pair again with a new address. |
| The pairing code is refused | It was used, mistyped, or older than ten minutes. Print a new one. |
| Remote `telar` is not found | The gateway looks beside its own executable first; keep the four programs in one directory. |
| Protocol/schema mismatch | Use matching builds; save running work before replacing/restarting the old runtime. |
| Unknown pane, workspace or worktree | Include `--machine box` and discover the machine's IDs again. |
| A clicked `localhost` link does not open | Nothing listens on that port there any more, or the server listens on an address that is not the machine's loopback. |
| Remote task lacks local edits | Commit required inputs before transfer; uncommitted files stay local. |

`telar machine check box --json` checks discovery and protocol compatibility.
It can start the runtime there.
