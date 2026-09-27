# Machines

Status: proposed. Nothing in this plan is implemented. It builds on
[remote attach](../flows/remote-attach.md), the
[worktrees and agent coordination plan](worktrees.md) and the agent control
commands in [agent control](../flows/agent-control.md).

This plan assumes the native GUI is the only client. Retiring the TUI is
being evaluated: telar targets graphical environments, and servers run only
the runtime and the CLI. The section [Retiring the TUI](#retiring-the-tui)
lists what the TUI still does for remote work and the order that keeps it.

Implementation must follow the [invariants](../invariants.md) and the
[architecture](../architecture.md). New terms go to
[CONTEXT.md](../../CONTEXT.md) before they appear in code.

## Problem

`telar --remote dev@box` attaches one client to one runtime on another
machine. A user who wants heavy work off their laptop has to open a second
window for the box, and nothing ties the two together: agents on the box are
invisible from the laptop, a coordinator on the laptop cannot start work on
the box, and the code has to reach the box by hand.

The goal is one client that holds every machine the user owns and lets them
send work to any of them:

- run a command on a chosen machine;
- create a worktree on a chosen machine from a local commit, with an agent in
  it, and bring its branch back;
- switch the whole view between machines the way the user switches
  workspaces;
- let a coordinator do all of the above through the CLI.

## Decisions

These were settled in the design discussion.

1. **Machines live in the client and the CLI.** Each runtime stays one per
   account and knows nothing about other runtimes. A local runtime acting as
   a hub was rejected: it sleeps with the laptop lid like any client.
2. **Work does not move between machines; git does.** A worktree lives on one
   machine for its whole life. Code travels as commits over git on the same
   SSH connection. Uncommitted changes do not travel.
3. **The fleet is symmetric.** Any machine may dispatch to any other. There
   is no home machine.
4. **The name is Machine.** "Host" already means the client's terminal or
   window, "Server" is on the avoid list for the runtime, "remote" means a
   pane in another workspace in `agent-navigation.md`, and "fleet" means the
   agents of one runtime in `worktrees.md`.
5. **The top bar always names the active machine.** It is the one cue that
   prevents typing into the wrong machine, so it is not configurable.
6. **The expanded sidebar gets a machine switcher; the rail does not.** The
   rail keeps one level: the workspaces of the active machine.
7. **The bottom bar gets an optional `telar.bar.machines()` widget.**
8. **No right sidebar.** A fleet-wide task board, if one is needed later,
   is a Telar view in a tab.
9. **Every machine surface reads one table and switches through one
   action.** The top bar segment, the picker, the sidebar switcher and the
   bottom widget read `Machines` and call `select_machine`.
10. **Selecting a machine switches the sidebar and the workbench together.**
    No surface shows one machine while input goes to another.
11. **A client may attach for metadata only.** It receives the workspace
    list, agents, notifications and metrics, and no pane screens.
12. **Configuration and plugins belong to where they act.** A runtime plugin
    (a proxy exchange listener) runs in each machine's runtime with that
    machine's configuration. Client configuration (bars, bindings, theme)
    runs once per client process and belongs to that kind of client: the
    GUI's configuration would not apply to another client kind.
13. **Clients are slots, not pointers.** The adapter keeps its clients in one
    fixed array; every other structure names a client by its slot.
14. **No automatic placement yet, but the data for it is collected.** Every
    fact a placement rule would need about a machine reaches the client from
    phase 2 on.
15. **The GUI is the client that holds machines.** The TUI gets no machine
    support; it keeps `telar --remote` unchanged until it is retired.
16. **The window never waits for a machine.** It opens first; every
    connection, local included, is established by a background job and
    reported to the window as a completion.
17. **Machines are declared in one file, `machines.json`.** The CLI and the
    GUI edit it through the same procedure; `config.lua` does not declare
    machines.
18. **No `telar machine connect`.** `enable` and `disable` edit the file,
    and every open window follows the file through the configuration
    watcher. There is no new channel from the CLI to the GUI.
19. **Interactive access from terminal-only devices is given up.** Without
    the TUI, a device that has only a terminal reaches telar through the CLI:
    `pane read`, `pane watch`, `pane send-keys`, `agent prompt`,
    `agent watch`. Neither a mobile client nor a minimal terminal client is
    part of this plan.
20. **The supported clients are the GUI on macOS and on Linux with
    Wayland.** X11 is out of scope. The Linux GUI already speaks only
    Wayland (`src/gui/linux` includes `wayland-client.h`; no X11 code
    exists). Retiring the TUI also leaves Windows without a client: the TUI
    is the only one that builds there today (`build/Application.zig` links
    `user32` for `telar-frontend`; `build/cross.zig` type-checks it for
    `x86_64-windows`).
21. **`telar` with no subcommand opens the GUI.** It takes the same options
    as `telar gui`, so `telar --remote DEST`, `telar --machine LABEL` and
    `telar -- COMMAND` open a window. `telar gui` stays as an alias: the
    packaged launchers run `telar gui --login-shell`
    (`packaging/linux/telar.desktop`, `build/packaging.zig`) and keep
    working unchanged. Without a display (a Linux session without
    `WAYLAND_DISPLAY`, or an SSH login), `telar` fails before starting
    anything, with a message that names the CLI commands of decision 19.
    How a macOS SSH login without a window server behaves must be checked;
    the message has to come from telar, not from AppKit.

## Prior art

Checked on 2026-09-26 against source: t3code `95030dc`, herdr `81ddfc6`,
WezTerm, Zed and VS Code at their default branches that day.

| Tool | Many machines in one client | Transport | Choosing where work runs | Version skew |
| --- | --- | --- | --- | --- |
| T3 Code | Yes. One connection supervisor per environment (`packages/client-runtime/src/connection/`) | One WebSocket per environment. Over SSH, `ssh -N -L` to a server on the remote loopback | Per thread draft, then locked (`BranchToolbar.tsx`, `envLocked`). Opt-in auto balance: `weight × cpus × (1 − cpu) × free memory`, samples older than 15 s skipped (`load-balancing.ts`) | Capability flags in `/.well-known/t3/environment` |
| herdr | Yes, since 0.9.0 (#3670). Only the selected machine streams screens; the rest send workspace, agent and notification metadata | `ssh host herdr remote-client-bridge` over stdio, one managed ControlMaster (`ControlPersist=600`) | `herdr --machine LABEL …`, never inherited, never falls back to Local (0.9.1, #3918) | Frozen hello with `methods[]` and `capabilities[]`; a missing method disables one action |
| WezTerm | Yes, as domains | SSH exec channel to `wezterm cli proxy` | `SpawnCommand.domain` | Exact codec version; SSH domains do not reconnect |
| Zed, VS Code | One remote per window | SSH, server installed under the remote home | Not applicable | Exact version; replay of unacknowledged messages on reconnect |

Common ground: ids are per runtime and the client qualifies them; one
connection failing never takes down the others; reconnects never prompt for
credentials or install anything; the user names the machine explicitly.

T3 Code groups clones of one repository across machines by their git remote
URL and states that the grouping never decides where work runs. herdr needed
"press Enter before shortcuts apply" after navigation reached another
machine, because keys hit the wrong one.

## Terms

To add to `CONTEXT.md`:

- **Machine**: one computer whose runtime a client can reach, through the
  local socket or an SSH forward. A machine has one runtime per account.
- **Local machine**: the machine the client process runs on. It needs no
  profile.
- **Machine profile**: the durable record of how to reach a machine: id,
  label, SSH destination, optional color, enabled. It never holds
  credentials.
- **Active machine**: the machine whose runtime the client presents and
  sends input to. A client has exactly one.
- **Repository identity**: the normalized URL of a repository's `origin`
  remote. It finds the clone of one project on another machine.
- **Dispatch**: starting work on another machine: a command, a worktree, an
  agent. The machine that dispatches pushes the commits it needs.

## What blocks it today

Checked on `main` at `fc0bc010`.

- **One connection per process.** The adapter signature takes one socket
  (`src/cli/client.zig:43`), `ClientInit.connection` is one pointer,
  `Client.runtime_transport` is one transport, and `Message.server` carries
  no source. `docs/flows/runtime-transport.md:13` states "one borrowed
  `SocketChannel` for the client's lifetime".
- **Ids collide.** `WorkspaceId`, `TabId`, `PaneId` and `RequestId` are bare
  `u64` counters that each runtime starts at 1 (`src/core/schema/id.zig`).
- **Revisions assume one source.** `WorkspaceListSnapshot.replace` drops any
  `revision <= self.revision` (`src/model/workspace/WorkspaceListSnapshot.zig:18`);
  `AgentSnapshot` does the same.
- **A lost socket ends the client.** `runtime-transport.md:145`: Telar does
  not retry. The ssh forward child has no keepalive.
- **The handshake requires the exact schema** and fails with
  `IncompatibleSchema`.

Keeping one `ClientModel` per connection removes the first three for free:
each machine gets its own `Client`, so ids, revisions and request ids never
share a table. The last two are phase 0.

## Design

### Machine profiles

Profiles live in `$XDG_CONFIG_HOME/telar/machines.json`, owner-only, next to
`trust.json`, which sets the precedent: a CLI-managed JSON file with strict
bounds. The CLI and the GUI both read it, and the CLI must read it without
running Lua, so it is plain data.

```json
{
  "version": 1,
  "machines": [
    { "id": "m-3f9c2a", "label": "box", "destination": "dev@box", "color": "red", "enabled": true }
  ]
}
```

- Unknown fields, duplicate ids or labels, and more than the table's
  capacity are rejected, the way `plugin.json` is validated.
- `destination` passes the same validation as `--remote` today
  (`src/cli/remote.zig`, `validateDestination`).
- The id is opaque and stable; the label can change.
- The local machine has no entry. Its label is the host name unless
  `local_label` is set in the file.
- With symmetric dispatch, each machine keeps its own file for the machines
  it can reach.

From the CLI:

```
telar machine add LABEL DESTINATION [--color COLOR] [--check]
telar machine remove LABEL
telar machine rename LABEL NEW_LABEL
telar machine enable|disable LABEL
telar machine list [--json]
telar machine check LABEL
```

- Writes replace the file atomically, never in place.
- `add --check` and `check` run the discovery step over SSH (the same
  `telar server endpoint` call as remote attach) and report the remote
  home, login shell and runtime socket, or the SSH error. They never install
  anything.
- `remove` does not touch the machine's runtime; its panes keep running.

`enabled` is the whole connection policy. An enabled machine has a
connection in every open window (metadata only unless it is active); a
disabled one has none. The runtime is never touched either way. A command
that connects or disconnects a machine would have to reach a window's
process, which only a new CLI-to-GUI route could do. The file already
reaches every window, so there is no `connect` or `disconnect`:

| Need | Answer |
| --- | --- |
| Connect a machine in the open windows | `telar machine enable LABEL` |
| Disconnect it everywhere, keep the profile | `telar machine disable LABEL` |
| Know whether a machine is reachable, from a script or a coordinator | `telar machine check LABEL`, which does its own SSH discovery and needs no window |
| Run something on it | `telar --machine LABEL …`, which uses SSH directly and needs no window |
| Retry now a machine the window gave up on | "Reconnect now" in the picker, window-local |

`telar machine list --json` reports profiles, not connection state:
connections belong to windows, and no CLI command above needs to know
them.

From the GUI:

- The machine picker has "Add machine", a form with label and destination
  built on the same form widget as the new-workspace form
  (`src/gui/widgets/overlays/WorkspaceForm.zig`). It calls the procedure
  behind `telar machine add`, then checks the connection.
- Each picker row offers enable or disable, rename and remove, all written
  to the file through the same procedures as the CLI. A machine in
  `reconnecting` or `failed` also offers "Reconnect now", which skips the
  remaining backoff in that window and writes nothing.
- Disabling or removing the active machine makes the local machine active
  and says why in a notice.
- The GUI follows `machines.json` through the existing configuration watch
  job. `config_reload.wait` (`src/client/resources/config_reload.zig`)
  sleeps one second, then compares fingerprints of the Lua configuration,
  the plugin registry and `trust.json`. It gains a separate fingerprint for
  `machines.json`. A change there only parses the profiles; it does not
  reload Lua, fonts or plugins. Open windows see a `telar machine enable`
  within about a second.
- Hand edits are valid; a file that fails validation leaves the previous
  profiles in place and shows the error, like a failed configuration reload.

### SSH

One managed ControlMaster per machine, its control socket in telar's
owner-only runtime directory, shared by the client forward, the CLI proxy and
git. Every call passes `BatchMode=yes`, so nothing in the background asks for
a password; a key or an agent is required, as remote attach already
documents. Every call adds `ServerAliveInterval` and `ServerAliveCountMax`.
No call forwards the ssh-agent.

### CLI dispatch

```
telar --machine LABEL <any telar command>
```

The CLI runs `ssh DESTINATION -- telar dispatch-argv <words>` through the
control master. OpenSSH joins the remote argv into one string for the remote
login shell, and sh, zsh and fish quote differently, so no quoting is right
for all of them. Each argument instead travels as `a` plus its unpadded
base64url form: letters, digits, `-` and `_`, which no shell reads as syntax.
`telar dispatch-argv` decodes them on the other side. The exit status and
stdout come back unchanged, so `--json` works across machines without new
code. See [machine dispatch](../flows/machine-dispatch.md).

- `--machine` is never read from the environment and never inherited from
  the pane the command runs in.
- A failure on the machine is a failure. The CLI never falls back to the
  local runtime.
- `--machine` names the local machine's label as well, so a coordinator can
  address every machine the same way.

This is the whole of phase 1. It gives command dispatch, remote worktrees
for branches the remote already has, and a coordinator that reaches other
machines, without touching the client.

### Worktrees on another machine

The worktree plan's `worktree_git.add` checks out `BRANCH` if it exists and
creates it from `--from` only if it does not
(`src/cli/worktree_git.zig`, `add`). Dispatch reuses that:

```
telar worktree create fix-tabs --machine box --from HEAD -- claude "…"

1. telar --machine box worktree resolve --repository <identity> --json
     → the clone's path on box
2. git push <box destination>:<path> <commit of HEAD>:refs/heads/fix-tabs
     → run locally, never forced
3. telar --machine box worktree create fix-tabs --dispatched-from <label> -- claude "…"
     → the phase 1 proxy; box checks out the branch it just received
```

`worktree create --machine` is the one command the proxy cannot forward
whole, because step 2 runs on the dispatching machine.

- **Finding the clone.** The remote CLI matches the repository identity
  against the workspaces of its runtime, running git in the CLI process as
  the worktree plan requires. Zero or several matches is an error that asks
  for `--workspace PATH`. Telar does not clone on demand in this plan.
- **Collisions fail early.** If `fix-tabs` exists on the remote with other
  history, the push is rejected as non-fast-forward and nothing is created.
- **Uncommitted changes.** The CLI prints how many files it does not send and
  continues.
- **Bringing work back.** The dispatcher fetches into a remote-tracking ref,
  without adding a remote to the user's repository:

  ```
  git fetch <box destination>:<path> +refs/heads/fix-tabs:refs/remotes/box/fix-tabs
  ```

  `telar worktree fetch BRANCH --machine box` wraps it.
- **Review** runs where the worktree is: `telar --machine box worktree diff
  fix-tabs`.
- **Removal** follows the worktree plan unchanged, proxied.

All git traffic starts on the dispatching machine, so dispatch never needs
SSH in the opposite direction.

The runtime's `Worktrees` row gains `dispatched_from`: a bounded label the
CLI passes, like `--title`. It is attribution only. A runtime still knows
nothing about other machines.

### The GUI as a remote client

Checked on `main` at `66abec21`.

**What works today.** `telar gui --remote DESTINATION` already attaches the
GUI to a remote runtime. `GuiOptions` wraps `RunOptions`
(`src/cli/arguments/GuiOptions.zig`), which parses `--remote`, and
`runNative` goes through the same `launch` as the TUI
(`src/cli/client.zig:34-75`): discovery, `ssh -N -L` forward, bounded
connect and schema handshake. `telar gui --no-config --remote -invalid`
fails with `InvalidRemoteDestination`, which only `remote.establish`
returns. The GUI always sends `graphics_shared = false`, so it has no
shared-memory issue over SSH.

**What is missing.** Checked by reading, not by attaching to a real host:

- `telar gui`'s usage line does not list `--remote`, and
  `docs/flows/remote-attach.md` and `tools/remote_smoke.py` validate only
  the TUI.
- The connection happens before the window exists. Discovery may take up to
  30 s and the forward up to another 10 s (`remote.zig`,
  `endpoint_timeout`, `connect_attempts × connect_interval_ms`), with no
  window on screen.
- SSH errors go to an inherited stderr (`.stderr = .inherit` on the forward,
  `std.debug.print` on discovery failure). A GUI launched from the Dock or
  Finder has no terminal, so a host-key or authentication failure is
  invisible.
- A transport error ends the window: `GuiAdapter.fail` records the error and
  wakes the loop to close (`src/gui/GuiAdapter.zig:362`).
- The forwarded socket path depends only on the destination
  (`remote-<hash>.sock`), and `establish` deletes any file at that path
  before starting ssh. A second window on the same machine takes the path
  from the first, and `Forward.stop` unlinks it when either exits. With one
  connection per window and no reconnect this is harmless today; with
  reconnect it is a bug.
- `WindowIdentity.acquire` hashes one endpoint path into the window's
  `ClientIdentity` (`src/gui/WindowIdentity.zig`). A window with several
  machines has several endpoints.
- A GUI started from the Dock inherits launchd's environment, not the login
  shell's. `telar gui --login-shell` exists for that
  (`src/main.zig`, `login_shell_module.relaunch`). SSH itself reads
  `~/.ssh/config` either way, but a key with a passphrase needs an agent
  reachable from the GUI's environment.

**Design.**

- **Connections are jobs.** Establishing a machine (discovery, forward,
  connect, handshake) is one background job that reports `machine_connected`
  with the result. `launch` no longer connects before calling the adapter;
  it opens the window, and the window starts one job per enabled machine,
  local first. The local machine's job calls `connectOrStart` as today.
- **SSH errors are data.** The job captures stderr, bounded, and the error
  lands in the machine's row. The picker and the top bar segment show it:
  unknown host key, authentication failed, `telar` not on the remote PATH,
  incompatible version.
- **A lost connection keeps the window.** A transport error on one machine
  changes its row to `reconnecting` instead of calling `fail`. `fail` stays
  for errors that make the whole window unusable, such as the GPU device.
- **Reconnect** restores the forward first, then the transport, then sends
  `request_runtime_state` with the same `ClientIdentity`, so the runtime
  restores the layout it kept in `ClientLayouts`. Backoff is capped and never
  prompts; `BatchMode=yes` guarantees that.
- **One forward per window and machine.** The forwarded path adds the
  window slot to the destination hash, so two windows never share or unlink
  each other's socket. The managed ControlMaster still shares one SSH
  connection and one authentication per machine across windows.
- **Identity per window and machine.** Each connection presents
  `ClientIdentity = hash(window slot, machine id)`. The window slot keeps its
  lease as today, taken from the local runtime's directory, which exists
  even with only remote machines, because the forwards live there.
- **Detach.** Disabling a machine stops its forward and frees its `Client`
  slot in every window; the runtime keeps every pane. Closing a window
  detaches every machine it held. `telar --machine box client detach ID`
  detaches one session from outside. There is no per-window disconnect.
- **`telar gui --remote DESTINATION`** stays as a shortcut: the window opens
  with that machine active. If the destination matches a profile, it uses
  the profile; otherwise the row is temporary and is not written to
  `machines.json`. `telar gui --machine LABEL` opens with a saved machine
  active.

### One client, several machines

The GUI adapter holds a `Machines` table and a fixed array of `Client`s, one
slot per connected machine. Each `Client` keeps its own transport,
`ClientModel`, request ids and revisions, unchanged.

The array is reserved once, with the table's capacity, and never grows or
moves. That matters beyond cache locality: jobs in flight carry pointers
into their `Client` (`Job.runtime_read` points at its transport), and the
adapter builds each `Client` in place. A growable list would invalidate them
on its first resize. Everything outside the array names a client by slot.

| Column | Meaning |
| --- | --- |
| `id`, `label`, `color` | from the profile; the local machine has an implicit row |
| `state` | `connecting`, `connected`, `reconnecting`, `failed`, `disabled` |
| `client` | slot in the client array, `null` while not connected |
| `attention` | whether any agent or notification on that machine needs the user |
| `cpu_percent`, `cpu_count`, `memory_used`, `memory_total` | from the machine's `system_metrics` |
| `metrics_received_at` | the client's clock when the sample arrived, so machines' clocks are never compared |
| `forward` | the SSH forward and its supervisor |

`Machines.active` is the active machine. The adapter presents only its
`Client`, and host input goes only to it.

Machine surfaces (top bar segment, picker, sidebar switcher, bottom widget)
read only the `Machines` columns. A machine's row is written when a message
from its runtime changes it (agent snapshot, notification, metrics), never
derived by walking the inactive clients' models. Per-frame code touches the
active `Client` and a few cache lines of `Machines`, however many machines
are connected.

Each slot costs one `Client` held inline. Measured on `66abec21` with
`@sizeOf` in the client test build: `ClientModel` is 1,237,048 bytes and
`Client` 1,857,648 bytes, about 1.8 MiB (on `fc0bc010` the transport was
4,232 of it). `ClientModel.init` allocates nothing, so that is the whole fixed cost;
pane records and their cell buffers are allocated per pane, and an inactive
machine has none. Eight machines reserve about 14 MiB. The array lives on the
heap. Shrinking what an inactive client holds is possible later and not
needed to start.

- **Only the active machine streams screens.** The others attach for
  metadata only: workspace list, agents, notifications and metrics. This
  needs no runtime or schema change. The runtime sends cells only through
  pane attachments (`prepareAttachment` in
  `src/backend/runtime/delivery/Delivery.zig`), and an attachment exists
  only after the client asks for a pane (`open_pane` in
  `src/backend/runtime/client_request.zig:51`) or creates one. The metadata
  lanes (layout snapshot, proxy status, agents, metrics, workspace list)
  depend only on `request_runtime_state`. The client change: an inactive
  machine's `Client` skips its initial `open_pane`
  (`client_startup.initialPaneRequest`), and leaving a machine detaches its
  panes so they stop streaming.
- **Switching** is `select_machine`. The adapter presents the other
  `Client`, draws its cached state dimmed and accepts no pane input until the
  first fresh frame arrives, then requests its pane snapshots.
- **Losing a machine** changes its row to `reconnecting`. Its supervisor
  retries with a capped backoff and never prompts. If it was active, its
  panes stay dimmed and refuse input.
- **Host facts** are written into every connected client, since they
  describe the same window.

This adds a level above `ClientModel`: one process now holds several client
models. `docs/architecture.md` must describe that level before code
depends on it.

### Configuration and plugins

Today `Client` owns the Lua generation and the plugin registry
(`Client.zig:54-55`), which was right while a process had one connection.
With several, they split by where they act:

- **Client configuration** (bars, bindings, theme, `telar.bar.dynamic`
  renders) moves to the adapter level: one Lua generation per process,
  shared by every machine's `Client`. A bar widget runs once, not once per
  machine. Its context reads the active machine, plus `Machines` for
  `telar.bar.machines()`.
- **Client plugin actions** go with the client configuration. Plugin code
  already runs in isolated workers, never in the client process
  (`docs/plugins.md`); what moves is the registry that starts them.
- **Runtime plugins**, such as exchange listeners on the proxy, stay in each
  machine's runtime and read that machine's configuration, as the remote
  runtime already does.
- **Client configuration is per client kind.** The GUI's configuration is
  not shipped to, or read by, another kind of client, if one is ever added.
- **Machines are not configuration.** They live in `machines.json`
  (see [Machine profiles](#machine-profiles)); the Lua configuration only
  places `telar.bar.machines()`.

### Presentation

**Top bar.** The machine is the first segment of the context, before the
workspace, in the machine's color, followed by the worktree when there is
one:

```
[● ● ●][≡]  box ▾ › telar › ⎇ fix-tabs │ tab1  tab2  tab3        [review]
```

With only the local machine, the segment is not drawn. A dot on it marks
attention on another machine, the way the rail's overflow counters keep the
attention of the workspaces they hide (`WorkspaceRail.zig`). Clicking it, or
a binding, opens the machine picker: each machine with its state, load and
attention, filtered by typing, built on the existing picker modal
(`src/gui/widgets/overlays/PickerModal.zig`). A machine in error shows its
SSH error in the picker row.

The window title's `{hostname}` token names the active machine, not the
host running the client (`GuiAdapter.zig:239` reads the local hostname
today).

**Sidebar.** When the sidebar is expanded and there are at least two
machines, a compact segmented control sits at its top: `laptop · box · gpu`,
each with its attention dot. It is drawn unlike the terminal tab strip, so
the two are not confused. Past what fits (about four at the default 284 px),
a `+N` item opens the picker. The rail shows no machines.

The projects list and agent cards below the switcher show the active
machine only. Task cards dispatched to another machine appear when that
machine is active; the attention dots lead there.

**Bottom bar.** `telar.bar.machines()` is one more bar source, placed like
`telar.bar.metrics()`:

```
● laptop  ● box 34%  ◌ gpu-rig
```

It is not in the default bars. The documentation of `telar.bar.metrics()`
states that it shows the active machine.

### Phase 0: one remote in the GUI that survives

Worth doing with one remote machine, required before the GUI holds several,
and required before the TUI is retired:

- `telar gui --remote` documented and validated: usage line, the remote
  attach flow document and a smoke test that drives the GUI (or the headless
  adapter) instead of the TUI;
- the window opens before the connection; the connection is a job; SSH
  errors reach the window;
- the window survives a lost socket: the connection's supervisor reconnects
  the forward and the transport with capped backoff and shows the cached
  state dimmed;
- the forward path carries the window slot;
- keepalives and the managed ControlMaster on the forward;
- a handshake that negotiates capabilities instead of requiring the exact
  schema, so a machine one release behind still attaches. Remote attach
  already negotiates before any mutation and installs nothing without
  approval (invariants), and that stays.

## Retiring the TUI

What the TUI does for remote work today, and what replaces it:

| TUI today | With the GUI as the only client |
| --- | --- |
| `telar --remote DEST` in a terminal | The same command opens a window (decision 21); `telar gui --remote DEST` works today. Then saved machines in the window |
| Runs over plain `ssh box` then `telar` from any terminal, including a phone SSH app (remote attach validation: "The Linux client also attached and detached through an SSH PTY") | Given up (decision 19). From a device without the GUI only the CLI remains: `pane read`, `pane watch`, `pane send-keys`, `agent prompt`, `agent watch` |
| `tools/remote_smoke.py` drives `telar --remote` in a PTY | The smoke test drives the GUI or the headless client (below) |
| Client identity from the terminal session (`TERM_SESSION_ID`, `WEZTERM_PANE`, the tty) | Window slot and machine id |
| Host shared memory decided by `supportsHostSharedMemory` and `SSH_CONNECTION` (`src/cli/client.zig`, `ClientLaunch.zig`) | Not needed: the GUI never uses shared-memory graphics |

Parts of this plan that assumed the TUI, and how they changed:

- The top bar segment was also drawn in the TUI's top bar. It is GUI only.
- Client configuration was "GUI and TUI". It is the GUI's.
- Phase 0 described a generic client surviving a lost socket. In the GUI
  that means replacing `GuiAdapter.fail` for transport errors, moving the
  connection out of `launch` into a job, and surfacing SSH errors without a
  terminal.
- `telar --remote` was the entry point. `telar gui --remote` and saved
  machines are.
- The TUI shared-graphics bootstrap issue listed below stops mattering once
  the TUI is gone.

### What depends on the TUI

Found with grep on `main` at `a9422328`: imports of `telar-frontend`,
paths under `src/frontend`, and tools that start `telar` without a
subcommand inside a PTY. Every row must be migrated or deliberately retired
before `src/frontend` is deleted.

**Tools.** They launch the TUI (`telar --no-config`, `telar --config …`,
`telar --remote …`) inside a PTY they control.

| Tool | What it measures or checks | Target |
| --- | --- | --- |
| `tools/latency_bench.sh`, `tools/echo_latency.py`, `tools/flood.py` | key-to-echo latency and output flood throughput against an isolated runtime | headless client |
| `tools/load_bench.sh`, `tools/load_latency.py` | echo latency while other panes flood, against tmux (`--mux telar\|tmux`) | headless client; the tmux comparison measured the TUI and loses its meaning |
| `tools/echo_path.py`, with `tools/echo_tail.py`, `tools/echo_trace.py`, `tools/test_echo_tools.py` | one key through controlled PTYs, validated with a VT | headless client |
| `tools/perf_e2e.py` | paired echo, load, slow-host and graphics cases; `tools/perf_suite.py` runs it, so it feeds the perf gate | headless client for echo and load. `slow-host` is a host terminal that reads slowly and `graphics` is Kitty output to a host terminal; both exist only for the TUI and need GUI-side replacements, not ports |
| `tools/graphics_roundtrip.py` | a synthetic Kitty host verifies a 4K image roundtrip through the TUI | retire; the GUI's own image coverage must be confirmed first (not checked) |
| `tools/terminal_runtime_bench.py` | DSR workload "inside an isolated, headless Telar TUI"; `tools/dod_measure.py` runs it | headless client |
| `tools/test_review_runtime.py` | review CLI and pane hooks on an isolated runtime with a TUI attached | headless client |
| `tools/test_cli_live.py` | CLI against a real runtime and a PTY client | headless client |
| `tools/tui_smoke.py` | plugin and CLI smoke with a TUI attached | headless client |
| `tools/remote_smoke.py` | remote home, shell PID and environment across detach and reconnect | `telar gui --remote` on macOS, headless client with `--remote` elsewhere |
| `tools/gui_tui_latency.py`, `tools/gui_tui_latency.m`, and its TUI mode in `tools/dod_measure.py` | Ghostty against the Telar GUI and the Telar TUI | drop the TUI mode; Ghostty and GUI stay |

The GUI already has its own measurements (`tools/gui_latency.py`,
`tools/gui_composition_latency.py`, `tools/gui_lifecycle.py`), all macOS
only. They cover the GUI's path, not what the TUI tools cover on Linux and
without a display.

**The headless client.** `HeadlessAdapter`
(`src/client/presentation/HeadlessAdapter.zig`) exists as a test double for
the client's own tests; it is not an executable. The tools above need a
client process that attaches to a runtime, sizes panes, takes keys and
consumes frames without a window, on Linux and macOS. The tests need two
different things from it, and only one of them is JSON.

- **Functional tests ask what the client shows.** Tabs, focused pane, pane
  text, sidebar, notifications. Most of it is already JSON:
  `telar layout get`, `sidebar get` and `pane copy` with
  `--client ID --json` route through the runtime to one client, and the
  client answers them in shared code (`src/client/connection/cli_control.zig`),
  not in the TUI or the GUI. A headless client that embeds `Client` answers
  them with no new code, so one test runs against the GUI on macOS and the
  headless client on Linux. A fact these commands lack becomes a new command
  on the same route, not a second output format.
- **Performance tools measure time.** JSON per frame would allocate and
  format inside the measured path, and the tools would measure the
  serializer. The headless client acknowledges frames like the GUI, records
  frame id, pane and timestamps in a bounded ring, and writes that ring as
  JSON once, at exit.

Shape of the executable:

- `telar-headless`, built by its own step (`zig build headless`), used only
  by tests and tools. It is not in the bundle, the packages or
  `telar cli install`.
- It is a presentation adapter, as `CONTEXT.md` already names the headless
  test adapter: `Client` plus an adapter without a window. It imports
  `telar-client`, `model` and `telar-core`; the GUI never imports it.
- It launches like the GUI: the same `RunOptions` (`--config`,
  `--no-config`, `--remote`, `-- COMMAND`), so `tools/remote_smoke.py`
  keeps its remote path.
- Host facts are fixed by flags: `--size COLSxROWS`, and a fixed capability
  set.
- Input arrives on stdin as a bounded line protocol that feeds the same host
  input entry the GUI's key events use: `key <name>`, `text <utf-8>`,
  `resize <cols>x<rows>`, `mark <label>`. It is not a terminal escape
  parser; that parser leaves with `src/frontend`.
- `to_host` effects (clipboard, opened links, notices) are recorded, not
  performed, and appear in the exit trace.
- `--trace PATH` writes the frame ring and the recorded effects as JSON at
  exit. `--dump PATH` writes, also at exit, the projection the adapter last
  received (`src/client/presentation/Projection.zig`): layout, tabs, focused
  pane, visible pane rows, sidebar rows, notifications. Both run after the
  measured work, never during it.

What it does not cover: the GUI's widget code, glyphs and Metal or Vulkan
presentation. Those stay with the GUI's tests and the `tools/gui_*`
measurements, which run on macOS only.

**Build and tests.**

| Place | Dependency |
| --- | --- |
| `build/freetype.zig:15` | the `freetype` module the GUI imports has its root at `src/frontend/graphics/freetype.zig`. Deleting `src/frontend` breaks the GUI build. It moves to `lib/` first |
| `build/Application.zig:151-188` | the `telar-frontend` module, `src/frontend/attachments/darwin.m`, and its import into the executable |
| `src/cli/client.zig` | `run` launches `frontend.ClientRun`, the TUI entry point |
| `src/transport_integration_test.zig` | imports `telar-frontend` |
| `benchmarks/` | eight files import `telar-frontend` (`main.zig`, `MultiplexerContext.zig`, `TransmitContext.zig`, `CursorContext.zig`, `IncrementalComposeContext.zig`, `PipelineContext.zig`, `GraphicsContext.zig`, `ClientUiContext.zig`). `zig build bench` runs them and `tools/perf_suite.py` feeds the perf gate with it. Benchmarks of client, model and runtime code keep going; those of the TUI's compositor and diff retire |
| `build/tests.zig` | `test-frontend`, `telar-cache-trace-tui`, the `src/frontend/ui/ui_tests.zig` and `src/frontend/frontend.zig` suites, and `test-compression-isolation`, which runs the frontend's "performance probe" and is part of `tools/perf_suite.py` |
| `build/Benchmarks.zig` | its own copy of the frontend module for benchmarks |
| `build/experiments.zig` | `exper`, `test-exper`, `exper-native`, all on `telar-frontend` |
| `build/cross.zig` | type-checks the frontend for `x86_64-windows` and Linux |

**Documentation.** `CLAUDE.md` (the "one pane, end to end" byte path draws
the TUI: `term.Screen diff`, `platform.Tty`), `docs/architecture.md` (the
package table lists `telar-frontend`), `CONTEXT.md`, `README.md`,
`docs/packaging.md` ("`telar` typed in a terminal is still the terminal
client"), `docs/configuration.md` (TUI-only bar and sidebar rules,
`--sidebar-renderer`), ADR 0011, and 43 documents under `docs/flows` that
mention the TUI.

### Order

1. **Phase 0 in the GUI.** After it, every remote capability of the TUI
   exists in the GUI, except the terminal-only access given up by
   decision 19.
2. **The headless client**: `telar-headless`, its stdin input protocol,
   the exit trace and dump, and the `--client` commands it answers through
   shared client code.
3. **Migrate the tools** in the table above to the headless client or the
   GUI, and retire the TUI-only cases. The perf gate and the smoke tests
   must pass on the new clients before anything is deleted.
4. **Move what the GUI shares out of `src/frontend`**: the `freetype`
   module root first.
5. **Split the benchmarks** and the perf suite so no gate depends on
   `telar-frontend`.
6. **Update the documentation** listed above.
7. **Delete `src/frontend`**, the `telar-frontend` module and its build
   steps, and the TUI launch path in `src/cli/client.zig`. In the same
   change, `telar` with no subcommand goes through `runNative` (decision
   21), the display check and its message land, and the TUI-only options
   leave `RunOptions` and the configuration: `--sidebar-renderer` and
   `client.sidebar.renderer` choose between `cells`, `kitty_hybrid` and
   `kitty_full`, ways of drawing the sidebar inside a terminal; outside
   `src/frontend` only a GUI test fixture sets it. `docs/packaging.md` stops saying that `telar` in a
   terminal is the terminal client.

Phases 1 to 4 of the machines work do not depend on the TUI and can
proceed before or after it.

## Security

- The fleet's trust is the union of its machines: if box can dispatch to the
  laptop, compromising box compromises the laptop. Telar adds nothing beyond
  the SSH keys the user configured, and must not widen them.
- No credentials in profiles. `BatchMode=yes` everywhere. No agent
  forwarding.
- `--machine` never falls back and is never inherited.
- Argv crosses SSH as base64url words that no shell parses.
- The worktree plan's focus rule applies across machines: telar refuses text
  to a pane that any attached client has focused, on whichever machine.
- Peer UID checks stay as they are; remote attach already refuses an SSH
  server that connects as another user.
- Git pushes never force and only create or fast-forward branches.

## Budgets

The active machine's interactive path is the same code as today. Inactive
machines deliver metadata only, on the observation path. Dispatch, git and
the CLI proxy run in the CLI process, never in the client loop. A switch
between machines shows cached state within one frame; fresh screens follow
at network speed.

## Found while researching, not reproduced

- The TUI bootstrap sends `graphics_shared = client_module.supportsSharedMemory()`
  whatever `--remote` says (`src/frontend/client/session/client_startup.zig:48`).
  The remote runtime then sends shared-memory names the client cannot map,
  and the client appears to fall back after the first image. Moot if the TUI
  is retired.
- Two GUI windows on the same remote share one forwarded socket path, and
  either one's exit unlinks it (see
  [The GUI as a remote client](#the-gui-as-a-remote-client)).
- `--socket` pointing at a forwarded socket whose forward is gone may start a
  local runtime at that path, because `Session.open` uses `connectOrStart`.
- `herdr-adoption.md` P12 still lists `endpoint.Remote`, `attach-stdio` and
  ControlMaster, which do not exist; only its "Deviation" paragraph matches
  the code.

## Placement data

Automatic placement is not planned. The data for it is: T3 Code's rule
(`weight × cpu_count × (1 − cpu) × free memory`, samples older than 15 s
skipped) is the reference for what a rule needs.

`SystemMetrics` carries `cpu_percent`, `memory_used_decigib` and the battery
(`src/core/schema/messages/SystemMetrics.zig`). It lacks the CPU count and
total memory, so neither free memory nor capacity can be computed. Phase 2
adds `cpu_count` and `memory_total_decigib`, and the `Machines` row records
when each sample arrived by the client's clock.

## Open questions

None at this stage.

## Phases

Each phase is done when its flow document exists under `docs/flows/`, its
tests exist and `zig build test` plus the perf gate pass.

0. **One remote in the GUI that survives**: `telar gui --remote` documented
   and smoke-tested, connection as a job, SSH errors in the window,
   reconnect supervisor instead of `fail`, forward path per window,
   keepalives, ControlMaster, capability handshake. The TUI can be retired
   after this phase.
1. **Profiles and `--machine`**: `machines.json`, `telar machine
   add|remove|rename|enable|disable|list|check` (no `connect`), the CLI
   proxy, the encoded argv.
2. **The GUI with several machines**: `Machines`, the client array,
   identity per window and machine, metadata-only attach, client
   configuration and plugin registry at the adapter level, `cpu_count` and
   `memory_total_decigib` in `SystemMetrics`, `select_machine`, top bar
   segment, picker with the add-machine form, sidebar switcher,
   `telar.bar.machines()`, `telar gui --machine`, the `machines.json`
   fingerprint in `config_reload.wait`, "Reconnect now".
3. **Worktrees on another machine**: `worktree resolve`, the push, `create
   --machine`, `worktree fetch`, `dispatched_from`. Needs the worktree plan
   merged.
4. **Coordinator across machines**: the coordinator skill passes
   `--machine`; placement by load if still wanted.
