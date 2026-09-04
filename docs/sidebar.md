# Sidebar integration contract

The runtime publishes bounded, self-contained agent snapshots assembled from
ProxyTLS activity, terminal-screen hints, and canonical workspace state.
Detection replaces the client snapshot; it does not own layout, focus,
scrolling, hit targets, or physical KGP placements.

## Ownership

The runtime owns agent truth and publishes stable `(pane_id, generation)` task
identity. `ClientModel` keeps one disposable `agents.Snapshot` replica.
`widgets.sidebar.State` keeps only visible interaction state such as scroll
position. The runtime retains the selected tab, pane focus, split trees,
sidebar geometry and workspace-list collapse for reconnecting clients; hover
and sidebar scroll still die with the client. None of this alters a runtime
task or agent.

Each entry carries workspace and tab labels, one-based pane position, a reduced
cwd label, and a session title in addition to provider and status. The runtime
resolves all of them against the same `(pane_id, generation)` immediately
before encoding. Workspace rename, tab rename, cwd changes, and pane topology
advance the agent revision.

`agent_snapshots.apply` is the protocol adapter. It maps borrowed wire entries
to `AgentInput` values and invokes `ApplyAgentSnapshotHandler`.
`ClientModel.reconcileAgentSnapshot` owns the transaction, while
`agents.Snapshot.replace` performs atomic bounded storage. The resulting commit
is validated and delivered by `DeliverAgentSnapshotHandler`, which owns
attachment, alert and animation ordering. Replacement:

- rejects revisions older than or equal to the current revision;
- rejects duplicate `(id, generation)` task keys;
- copies all strings into fixed-capacity storage;
- accepts at most 64 tasks;
- allocates nothing.

Task keys carry a generation so a delayed action cannot target a new task that
reused an old numeric ID. A task may carry a `pane_id`; selecting it then uses
`ClientModel.planAgentNavigation`, which returns either local tab and pane
focus or a runtime pane handoff. Input code never reads replica storage.

## Session titles

Every detected agent starts with a local placeholder such as `New Codex
session`. Title generation is disabled unless `runtime.agent_descriptions` is
configured in Lua. When enabled, Telar captures at most 4096 bytes from the
first submitted user request. When the agent first moves to `working`, Telar
runs the configured argv command in parallel and outside the interactive path.
The request is written to stdin and never appears in process arguments or
history storage.

The queue admits eight pending jobs and one active child. Output is capped at
512 bytes, must normalize to one control-free UTF-8 line of at most 96 bytes,
and is guarded by a deadline. Missing executables, queue pressure, timeout,
invalid output, stale pane generations, and stale session IDs retain the
placeholder with a deterministic failure state. There are no automatic
retries. A manual title has higher authority than a generated completion.

A name the user gives the session inside the agent (`/name` in Pi, `/rename`
in Claude Code and Codex) reaches the runtime through the agent's hooks or the
file it records its session in ([agent rename](flows/agent-rename.md)) as a
title with source `agent`. It
replaces a generated or manual title, is checkpointed like a manual one, and
clearing the name inside the agent returns the row to its placeholder unless a
manual title was set afterwards.

Only the validated title, source, and state are persisted by `session_id` in
the history database. Prompt bytes are cleared when the job starts or is
discarded.

## Focus projection

The focused pane is the sole source of truth for the agent highlight. Sidebar
composition projects the active tab's focused pane through the current agent
snapshot and highlights the matching agent. It highlights no agent when the
focused pane has no matching agent.

Clicking an agent is a navigation action, not a second kind of focus. It may
switch workspace or tab before focusing the agent's pane. The highlight follows
only after pane focus changes. Pane navigation and workspace or tab changes
recompute the same projection, so the sidebar never preserves an independent
agent selection. A cross-workspace handoff restores the target tab's pane order
before applying focus, so navigation does not renumber the selected pane. When
the runtime still reports the same pane set, the client restores its bookmarked
split tree, including split axes and ratios. If the pane set changed while the
workspace was hidden, the client falls back to canonical pane order before
applying focus. Every successful transition, including workspace creation,
bookmarks the workspace being left before destroying its client-side tab
models.

The runtime pane position remains immutable in `agents.Snapshot`. When the
active client layout has a different local display order, the sidebar derives
that pane index while rendering. Neither `View.render` nor a widget rewrites
the runtime replica.

## Rendering boundary

Cells own every string, the editable search field, terminal cursor, hover,
focus marker, tabs, section headers, status, footer, and hit target. The
cell renderer is complete by itself.

Each agent card stays three rows high:

1. session title, with status width reserved on the right;
2. `workspace › tab › pane N`;
3. provider and abbreviated cwd, truncated from the left.

KGP owns two reusable assets: one three-row focused-agent card and an official
provider-mark atlas. The card is an antialiased rounded rectangle below the
cell layer. Cells keep the same solid fill except at its four corner cells,
where the KGP alpha edge remains visible. Themes whose focus color is not RGB
retain the square cell-only fallback.

Changing hover never changes KGP input. Moving the focused agent or a provider
mark changes placements only. Pixel transmission happens after a theme or
cell-size change, or when an asset first becomes necessary. The focused-card
raster is capped at 64 KiB. Media failure leaves the cell actions intact.

## Geometry

The sidebar is visible only when the client can reserve 42 columns for it and
20 for the workbench. Its default preferred width is 62 columns. Keybindings
move that preference by two columns, and dragging the rightmost sidebar column
selects an exact width. Host geometry clamps only the visible width: shrinking
the terminal does not overwrite the preference, so expanding it restores the
chosen size. While visible, the sidebar owns the complete left column. The top
bar, bottom bar and workbench use the remaining width. Hiding it expands all
three regions to the full client width.

## Detector wiring

The frontend message handler:

1. validates the runtime message and its revision;
2. maps runtime agent records to bounded `AgentInput` values;
3. invokes `ApplyAgentSnapshotHandler`;
4. commits the replica and `Version.agents` in `ClientModel`;
5. synchronizes attachment resources and emits bounded actionable alerts;
6. lets `Presenter` observe the version and pass the immutable snapshot to
   `View.render` on the next paced frame.

The snapshot path never requests a draw for the replica itself. `Presenter`
compares the model version with the last version it painted, resets transient
sidebar scroll, invalidates chrome and renders the latest snapshot. Several
runtime revisions inside one frame interval therefore fold into one projection.

Only status changes for identities present in the previous revision can emit
an alert. Transitions to `blocked`, `done` and `failed` are actionable, and
the use case caps them to the notification center's fixed capacity. Agent
sounds remain separate runtime decisions; the client accepts a sound only
when its exact pane generation exists in `ClientModel`.

Detection remains on the observation path. Snapshot rendering and input
routing perform no filesystem, process, JSON, network, or plugin work.

Proxy request start and response activity mark an agent as working. A verified
provider turn completion marks it ready once no other model exchange remains;
successful transport completion alone leaves it working. Failures visible to
the protocol observer mark it failed. This includes HTTP/1.1 and HPACK-decoded
HTTP/2 response statuses of 400 or greater, plus HTTP/2 stream resets.
HTTP/2 activity is keyed by connection and stream. Completing one multiplexed
stream leaves the agent working while another stream is active; a
connection-level failure settles every remaining stream for that connection.
A visible permission prompt is stronger than network activity. Terminal
working hints also override an early network completion. A ready prompt
requires established Claude identity and three samples before it can recover a
missing proxy completion. Codex's branded input prompt confirms `ready` once
no working phrase remains visible above it. Every record carries its source,
confidence, process and session identity, sequence, timestamps, and expiry.
None of these presentation hints authorizes approval or input.
