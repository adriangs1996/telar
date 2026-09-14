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

Three fields describe what the agent wants from the person:

| Field | Bound | Source |
| --- | --- | --- |
| `blocked_reason` | `none`, `permission`, `question`, `plan`, `other`; `none` unless the status is `blocked` | The lifecycle report when its hook names one (Claude Code `permission_prompt`, elicitation notifications, `AskUserQuestion` and `ExitPlanMode` tool starts; Codex `PermissionRequest`; Pi dialogs). Without a report, a blocked agent whose last proxy response closed on a tool request while no exchange is open is `permission`; any other blocked state is `other`. |
| `last_event` | one control-free UTF-8 line of at most 96 bytes | The event line of the lifecycle report the projection follows: the prompt text while blocked, the last tool call (`» Edit src/client/bars/Output.zig`) while working, the first line of the final assistant message when done. Empty while any other evidence decides. |
| `status_age_s` | `u32` seconds | The runtime clock at encode time minus the last projected status change. It is never part of the revision; the client adds the time since the snapshot arrived. |

A changed reason or event line advances the agent revision like a label. The
reason and the line are presentation only: they choose an icon and a chip and
never authorize an answer on the agent's behalf.

## Attention order

`agents/attention.zig` in `telar-client` is the one comparator every surface
uses for agents: the sidebar list, "next agent that needs me" and toast
order. Groups from first to last: needs input (`blocked`, `failed`), working,
ready-unseen (`done`), idle (`ready`), `unknown`. Inside a group the smallest
`status_age_s` comes first; equal ages fall back to pane id and generation so
the order is stable across revisions. It is pure and allocation-free.

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

1. workspace name, with the age of the last status change right-aligned;
2. session title;
3. last event, with the status icon in its color and the provider mark on
   the right.

The card shows no location row (`workspace › tab › pane N`) and no cwd;
the top bar shows the selected workspace's location instead. The TUI cell
renderer still draws the previous rows; the entry fields above are already on
the wire.

The GUI draws the card in device pixels inside the sidebar's cell column
(`src/gui/chrome/Sidebar.zig`, `AgentCard.zig`). With glyph height `g` from
the chrome font metrics (`TerminalMetrics.pixel_height`): row height
`ceil(1.25 g)`, card height `3 rows + 12`, card spacing 3, sidebar margins 8,
card padding 8 horizontal and 6 vertical, radius 8, provider chip 16. The
header reads `agents` with `N · M need you` right-aligned, `M` counting
`blocked` and `failed`. There are no section headers: the list is one array
of at most 64 replica indices sorted by `agent_attention.lessThan` when the
snapshot identity (revision, replica, length) changes, never per frame. The
age is `status_age_s` plus the monotonic seconds since that snapshot was
first painted, formatted `now`, `3m`, `2h`, `1d`; it refreshes whenever a
frame is painted. Tokens leave from the right as the card narrows: age, then
the provider mark, then the last event; the status glyph always stays. The
working glyph `◌` pulses through six alpha steps between 1.0 and 0.35 over
17 animation frames (about 2 s at 120 ms per frame). The selected card is
the focused pane's agent: `surface0` fill and an inner 1px `surface1` ring.
The provider mark of a built-in provider is the official artwork from the
embedded sheet, one sprite quad of 16 logical pixels sampled from the RGBA
page beside the glyph atlas; a custom or unknown provider keeps a rounded
chip with its glyph. The project slot of the first row shows the workspace's
favicon (`favicon.png`, then `.telar/icon.png` in the workspace root, PNG
only) once the client's favicon worker has resolved it, else the generic
glyph. The image never crosses the wire; the GUI reads, decodes and resizes
it off the interactive path and keeps at most 64 favicons per page. Hits are cell-based: one `focus_agent` target per
card covering the rows its pixels touch; a boundary row shared by two cards
belongs to the later one. The wheel scrolls one card pitch. The rightmost
sidebar column stays the resize border.

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
