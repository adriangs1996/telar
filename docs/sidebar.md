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

1. workspace name, with a right-aligned readable state and working duration;
2. session title in the regular face at body size;
3. latest event while `working`, otherwise the branch from that agent's
   workspace snapshot, with a small, dimmed provider symbol on the right.

The third row reads only the existing replicas. Workspace identity selects
its branch, independent of the focused workspace. Missing Git observations,
non-repository workspaces and worktree-only locations without a workspace-list
entry leave the row empty. A working agent with no event also leaves it empty.
A workspace-list revision can update the branch without an agent revision.
The card shows no location row (`workspace › tab › pane N`) and no cwd;
the top bar shows the selected workspace's location instead. The TUI cell
renderer retains its own layout.

The GUI draws cards in device pixels inside the sidebar band
(`src/gui/chrome/Sidebar.zig`, `AgentCard.zig`). Text uses the `small`, `title`,
`small` line boxes. The title is body-sized without the pane header's height cap. Insets are 10 horizontal and 8 vertical logical pixels,
with 4 logical pixels before the title and 2 before the detail. Card spacing
is 3, sidebar margins 8, radius 8 and provider symbols 14 logical pixels.
These lengths follow the chrome's display/font ratio before being rounded.
The header reads `agents`. One array of at most 64 replica indices is sorted by
`agent_attention.lessThan` when snapshot identity changes, never per frame.

The top-right state combines an icon with `Working`, `Approval`, `Question`,
`Review plan`, `Needs input`, `Done`, `Failed` or `Unknown`. Ready agents show
only their status age. Working duration uses `0s` through `59s`, then `1m`,
`1h` or `1d`; the same duration is never repeated elsewhere in the card.
It adds monotonic seconds since the agent snapshot first painted. Narrow
cards drop the duration, then the state word before clipping the icon;
project, title and detail fit independently with an ellipsis. The provider
symbol disappears only when its own box cannot fit.

Only the working glyph pulses through six alpha steps between 1.0 and 0.35
across 17 animation frames. The state word and duration remain steady.
The focused pane's card has `surface0` fill and an inner 1px `surface1` ring.
Built-in providers use the embedded symbol atlas at 60% opacity. OpenAI
is a white mask tinted with `text`; Claude and Pi retain their source colors. Custom providers keep an unboxed glyph.
The workspace favicon remains colored and is resolved by the existing worker.
One clipped `focus_agent` hit target covers each visible card. The wheel
scrolls one card pitch; the band's last pixel column is its edge and a 6 px
strip centered on it remains the resize handle.

KGP owns two reusable assets: one three-row focused-agent card and the same
T3 Code provider atlas as the GUI. The card is an antialiased rounded rectangle below the
cell layer. Cells keep the same solid fill except at its four corner cells,
where the KGP alpha edge remains visible. Themes whose focus color is not RGB
retain the square cell-only fallback.

Changing hover never changes KGP input. Moving the focused agent or a provider
mark changes placements only. Pixel transmission happens after a theme or
cell-size change, or when an asset first becomes necessary. The focused-card
raster is capped at 64 KiB. Media failure leaves the cell actions intact.

## Geometry

Visibility is shared: `sidebar_visible` lives in the client model, the
runtime retains it for reconnecting clients and `toggle_sidebar` flips it
in both clients. Width is not.

In the TUI the sidebar is a column of cells. It is visible only when the
client can reserve 42 columns for it and 20 for the workbench. Its default
preferred width is 42 columns. Keybindings move that preference by two
columns, and dragging the rightmost sidebar column selects an exact width.
Host geometry clamps only the visible width: shrinking the terminal does
not overwrite the preference, so expanding it restores the chosen size.
The runtime retains this column preference in the client layout replica;
it is TUI-only. While visible, the sidebar owns the complete left column.
The top bar, bottom bar and workbench use the remaining width. Hiding it
expands all three regions to the full client width.

In the GUI the sidebar is a band of device pixels (`chrome/SidebarBand.zig`)
that the renderer takes off the window width before it counts columns, the
way the top bar, tab strip and status bar come off the height. Its width is
`gui.sidebar.width` logical pixels (default 284, bounds 220..480) scaled by
the display and rounded, and an 8 logical px gap separates the edge line
from the first cell column. The band is clamped so the workbench keeps at
least 20 columns after the gap and the right window padding; a window that
cannot hold the narrowest band beside that workbench hides it. The width is
a disposable host preference (`SidebarPreference`) seeded from the Lua
value: `resize_sidebar` moves it by 16 logical px, dragging the edge sets
the exact width under the pointer, both clamp to the same bounds, and a
reload that changes `gui.sidebar.width` replaces it while one that does not
keeps the interactive choice. Nothing persists it outside the Lua file:
the window lease holds no data and there is no per-window preference
store. The PTY sees complete cells only; the band, the gap and trailing
pixels are chrome.

The band runs from under the tab strip to the status bar. Inside it, at
margin 8: the header row, the list, and a footer row one terminal cell
tall where the Lua `bars.sidebar_footer` slots paint through a lent cell
row; the footer appears once the band is at least five cell rows tall.

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
