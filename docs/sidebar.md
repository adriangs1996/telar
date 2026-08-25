# Sidebar integration contract

The runtime publishes bounded agent snapshots assembled from ProxyTLS activity
and terminal-screen hints. Detection replaces the client snapshot; it does not
own layout, focus, search, scrolling, hit targets, or physical KGP placements.

## Ownership

The runtime owns agent truth and publishes stable `(pane_id, generation)` task
identity. The client keeps one disposable `widgets.sidebar.Snapshot` replica
and all visible interaction state in `widgets.sidebar.State`. Killing the
client loses the selected tab, selected task, search text, scope expansion, and
scroll offset. It does not alter any runtime task or agent.

`Snapshot.replace` is the client adapter boundary. An observation or IPC
handler supplies a revision and `TaskInput` values. Replacement:

- rejects revisions older than or equal to the current revision;
- rejects duplicate `(id, generation)` task keys;
- copies all strings into fixed-capacity storage;
- accepts at most 64 tasks;
- allocates nothing.

Task keys carry a generation so a delayed action cannot target a new task that
reused an old numeric ID. A task may carry a `pane_id`; selecting it then uses
the existing semantic pane-focus operation.

Buttons whose runtime behavior does not exist yet return a typed
`SidebarIntent` from `client_ui.State.handleMouse`. The current client does not
turn those intents into runtime messages. Adding detection must not smuggle in
approval, creation, or review behavior; each intent needs its own explicit
runtime command and authority check.

## Rendering boundary

Cells own every string, the editable search field, terminal cursor, hover,
selection marker, tabs, section headers, status, footer, and hit target. The
cell renderer is complete by itself.

KGP owns four reusable asset families:

1. the panel background;
2. one three-row selected-task card;
3. an official provider-mark atlas;
4. an atlas for neutral and primary control fills.

Changing hover never changes KGP input. Moving a selected task or a provider
mark changes placements only. Pixel transmission happens after a theme,
cell-size, or panel-size change, or when an atlas first becomes necessary.
Media failure leaves the cell actions intact.

## Geometry

The sidebar is visible only when the client can reserve 42 columns for it and
20 for the workbench. It grows with the terminal up to 62 columns. Below that
threshold the layout hides it while preserving `sidebar_requested`, so a later
resize restores it without changing user intent.

## Detector wiring

The frontend message handler:

1. validates the runtime message and its revision;
2. maps runtime agent records to bounded `TaskInput` values;
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
missing proxy completion. Every record carries its source, confidence, process
and session identity, sequence, timestamps, and expiry. None of these
presentation hints authorizes approval or input.
