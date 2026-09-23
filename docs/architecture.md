# Architecture

Telar has two processes. The runtime owns what must survive the UI: children,
PTYs, one terminal per pane, agents and history. A client owns what only
matters while someone is looking: layout, focus, hover, selection and scroll.
Ask what happens to a piece of state when the client is killed. If the session
is ruined, it belongs to the runtime.

This document describes the shape both processes converge on. Code that still
has another shape is migration debt, not a template; the
[migration plan](plans/procedural-model.md) tracks it. The rules that protect
users regardless of shape live in [invariants](invariants.md), and names follow
[naming](naming.md).

## One flat model per process

Each process keeps its state in one struct: `RuntimeModel` in the runtime and
`ClientModel` in every client connection.

- Singletons are plain fields: host facts, configuration, the active tab, the
  focused pane, the input mode.
- Entities that repeat live in tables. A table is a struct of columns indexed
  by a slot, with a `count` and a `GenericSlotIndex` from id to slot.
- Relations are ids or slots stored in a column. A pane stores its tab; a tab
  does not store its panes. No entity holds a pointer to another, and no
  table nests inside another table's rows.
- Data that only some rows need gets its own table keyed by the owner. Agent
  state lives in `agents`, keyed by pane, so terminal panes do not carry it.

```zig
// ClientModel.zig
host: Host,           // facts the adapter writes: size, capabilities, time
config: Config,       // the active configuration generation, one copy
input_mode: InputMode,
tabs: Tabs,           // ordered tabs; the active one is `tabs.active`
panes: Panes,         // every pane of every tab
agents: Agents,
requests: Requests,   // in flight: id, kind, target, deadline
to_runtime: Outbox,
to_host: HostEffects,
revisions: Revisions,
```

```zig
// Tabs.zig: one row per tab, ordered by position
location: [capacity]core.TabLocation,
label: [capacity]Label,
layout: [capacity]WorkspaceLayout,   // the tab's split tree, one bounded value
snapshot_loaded: [capacity]bool,
count: usize,
active: usize,

// Panes.zig: one row per pane
record: [capacity]?*Pane,            // heap record; its location names its tab
index: core.GenericSlotIndex(2 * capacity),
count: usize,
```

A tab's slot is its position, so it changes when tabs move; anything kept
across calls or messages uses `core.TabId`. A pane's record stays on the heap
because its cell buffers are large and its address must survive tab moves;
lookups go through the index, never through the tab.

## Procedures

Behavior is plain functions that take the model, grouped by flow in snake_case
files named after [`docs/flows`](flows/README.md).

- Any code reads any column.
- Tables own their structural changes only: adding and removing rows, and
  keeping `count` and the index consistent (`panes.add`, `panes.remove`,
  `panes.find`).
- Flow procedures write ordinary columns directly.
- A transition that must change several columns together happens inside one
  procedure, never split across callers.
- Invariants that span tables are checked by `model_invariants.check(model)`,
  which the TUI test harness runs after every settled step and the model's
  flow tests run after every scenario.

```zig
// src/model/panes/pane_frame.zig
pub fn receive(model: *ClientModel, frame: core.FrameView) !PaneFrameOutcome {
    const pane = model.panes.find(frame.pane_id) orelse return .detached;
    if (!pane.attached) {
        return .detached;
    }

    if (frame.base_frame_id != 0 and frame.base_frame_id != pane.applied_frame_id) {
        try model.to_runtime.push(.{ .request_snapshot = .{ .pane_id = frame.pane_id, .known_frame_id = pane.applied_frame_id } });
        return .{ .resync = .{ .pane_id = frame.pane_id, .known_frame_id = pane.applied_frame_id } };
    }

    const applied = try pane.applyFrame(frame);
    model.frame_revision +%= 1;
    try model.to_runtime.push(.{ .frame_ack = .{ .pane_id = frame.pane_id, .frame_id = frame.frame_id } });
    // ...
}
```

## Dispatch

Each process has one `update`. Runtime messages, worker completions and
timers are all messages; the switch calls one procedure per branch, and a
reader follows any flow from there. The client's `update` lives on
`AttachedClient` (`src/client/AttachedClient.zig`) because some branches also
touch the Lua VM and the transport, which are not model state; each adapter
wraps `client.Message` as one variant of its own event union and handles only
its host events itself.

```zig
pub fn update(self: *AttachedClient, message: Message) !?u8 {
    switch (message) {
        .server => |result| return self.receiveRuntime(result),
        .sent => |result| try self.completeRuntimeSend(result),
        .bar_tick => |result| try bar_updates.handleTick(self, result),
        .config_reload => |result| _ = try self.completeConfigReload(result),
        // ...
    }

    return null;
}
```

After the switch, the process flushes once. The runtime delivers pending
output to every affected client in a single pass; the client compares
revisions once and schedules presentation.

## The host boundary is data

The TUI, the native GUI and the headless test adapter are presentation
adapters. Each owns its host resources: terminal or window, renderer, output
buffers, pacing.

- The adapter writes host facts into `model.host` before calling `update`.
- Procedures push host requests (play a sound, notify, open a link, write
  the clipboard) into `model.to_host`. The adapter drains it with an
  exhaustive switch. A host without a feature writes that branch as an empty
  arm, visible in one line.
- Procedures push runtime messages into `model.to_runtime`.
- Workers start from a procedure and report through a completion message.
  They carry ids and generations, never pointers.
- A synchronous call into the adapter remains only where the answer cannot be
  a fact written beforehand, such as hit testing the adapter's own chrome.

## Change detection

`model.revisions` holds one counter per fact whose change makes some consumer
do something different: layout, chrome, pane damage. Derived data such as the
layout snapshot or the accessibility tree is computed in one place and cached
by the revisions it depends on. Nothing is recomputed per frame or per event
unless its inputs changed.

## Memory

Tables have fixed capacity and are reserved once when the model is created.
Creating a pane allocates its cell buffer; the interactive path allocates
nothing. Columns keep what each hot loop reads contiguous, and a lookup by id
is one index probe, not a walk through nested structs.

## Packages

| Package | Owns |
| --- | --- |
| `telar-core` | cells, buffers, geometry and wire values shared by both processes |
| `telar-backend` | the runtime: children, PTYs, emulation, agents, history, proxy |
| `model` | client state and its procedures, with no I/O, Lua or host access |
| `telar-client` | the client shell: runtime socket, Lua VM, workers, inbox |
| `telar-frontend` | the TUI adapter: host terminal, decoder, compositor, diff, pacing |
| `telar-gui` | the native adapter: glyph atlas and quads drawn by Metal or Vulkan |

Backend and client packages never import each other; both import core. The
TUI and GUI never import each other; what both embed lives in `assets`.
`src/main.zig` selects a CLI entrypoint.

The path a byte takes through one pane is drawn in [`AGENTS.md`](../AGENTS.md#one-pane-end-to-end).
