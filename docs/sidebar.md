# Sidebar integration contract

The runtime publishes bounded, self-contained agent snapshots assembled from
ProxyTLS activity, terminal-screen hints, and canonical workspace state.
Detection replaces the client snapshot; it does not own layout, focus,
scrolling, hit targets, or physical KGP placements.

## Ownership

The runtime owns agent truth and publishes stable `(pane_id, generation)` task
identity. The client keeps one disposable `widgets.sidebar.Snapshot` replica
and all visible interaction state in `widgets.sidebar.State`. Killing the
client loses the selected tab, pane focus, search text, scope expansion, and
scroll offset. It does not alter any runtime task or agent.

Each entry carries workspace and tab labels, one-based pane position, a reduced
cwd label, and a session title in addition to provider and status. The runtime
resolves all of them against the same `(pane_id, generation)` immediately
before encoding. Workspace rename, tab rename, cwd changes, and pane topology
advance the agent revision.

`Snapshot.replace` is the client adapter boundary. An observation or IPC
handler supplies a revision and `AgentInput` values. Replacement:

- rejects revisions older than or equal to the current revision;
- rejects duplicate `(id, generation)` task keys;
- copies all strings into fixed-capacity storage;
- accepts at most 64 tasks;
- allocates nothing.

Task keys carry a generation so a delayed action cannot target a new task that
reused an old numeric ID. A task may carry a `pane_id`; selecting it then uses
the existing semantic pane-focus operation.

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

Only the validated title, source, and state are persisted by `session_id` in
the history database. Prompt bytes are cleared when the job starts or is
discarded.

## Focus projection

The focused pane is the sole source of truth for the agent highlight. The
client projects the active tab's focused pane through the current agent
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

Buttons whose runtime behavior does not exist yet return a typed
`SidebarIntent` from `client_ui.State.handleMouse`. The current client does not
turn those intents into runtime messages. Adding detection must not smuggle in
approval, creation, or review behavior; each intent needs its own explicit
runtime command and authority check.

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
20 for the workbench. It grows with the terminal up to 62 columns. Below that
threshold the layout hides it while preserving `sidebar_requested`, so a later
resize restores it without changing user intent.

## Detector wiring

The frontend message handler:

1. validates the runtime message and its revision;
2. maps runtime agent records to bounded `AgentInput` values;
3. calls `client_ui.State.replaceSidebarSnapshot`;
4. requests one client redraw when replacement succeeds.

Detection remains on the observation path. Snapshot rendering and input
routing perform no filesystem, process, JSON, network, or plugin work.

Proxy request start and response activity mark an agent as working; completion
marks it ready, while failures visible to the protocol observer mark it failed.
This includes HTTP/1.1 and HPACK-decoded HTTP/2 response statuses of 400 or
greater, plus HTTP/2 stream resets.
HTTP/2 activity is keyed by connection and stream. Completing one multiplexed
stream leaves the agent working while another stream is active; a
connection-level failure settles every remaining stream for that connection.
A visible permission prompt is stronger than network activity. Terminal
working hints also override an early network completion. A ready prompt
requires established Claude identity and three samples before it can recover a
missing proxy completion. Codex's explicit branded input prompt confirms
`ready` in one sample. Every record carries its source, confidence, process and
session identity, sequence, timestamps, and expiry. None of these presentation
hints authorizes approval or input.
