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
reader follows any flow from there. The client's `update` lives on `Client`
(`src/client/execution/Client.zig`), the one struct that holds the model
beside what is not model state: the runtime transport, the Lua VM and plugin
registry, and the jobs an event starts. Each adapter wraps `client.Message`
as one variant of its own event union and handles only its host events
itself.

```zig
pub fn update(self: *Client, message: Message) !?u8 {
    switch (message) {
        .server => |result| return runtime_io.receiveRuntime(self, result),
        .sent => |result| try runtime_io.completeRuntimeSend(self, result),
        .bar_tick => |result| try bar_updates.handleTick(self, result),
        .config_reload => |result| _ = try config_adoption.completeConfigReload(self, result),
        // ...
    }

    return null;
}
```

`Client` has no other behavior than `init`, `deinit`, `update`, `flush` and
`failJob`. Client procedures live in flow files under `src/client`: one that
touches only the model takes `model: *ClientModel`; one that also reaches the
transport, Lua, the clock or the job queue takes `client: *Client`.

After the switch, the process flushes once. The runtime delivers pending
output to every affected client in a single pass. The client's adapter calls
`Client.flush`, which writes what the event left in `model.to_runtime`, then
starts the jobs the event queued; the presenter compares revisions once and
schedules presentation.

## The host boundary is data

The TUI (`TerminalAdapter`), the native GUI (`GuiAdapter`) and the headless
test adapter are presentation adapters. Each owns its host resources:
terminal or window, renderer, output buffers, pacing. Each embeds one
`Client` and drains it after every event.

- The adapter writes host facts into `model.host` before calling `update`.
- Procedures push host requests (write the clipboard, show a notice on the
  outer terminal, capture clipboard media) into `model.to_host`. The adapter
  drains it with an exhaustive switch. A host without a feature writes that
  branch as an empty arm, visible in one line.
- Procedures push runtime messages into `model.to_runtime`; `flush` writes
  them once per event.
- Procedures start workers by pushing a `client.Job` into
  `client.to_workers`. The adapter starts each job off the event loop and
  the job reports through its completion message. A job the adapter cannot
  start finishes through `Client.failJob` as that same completion carrying
  the error, so one handler releases what starting it reserved. The queue
  lives in `Client`, not the model, because jobs carry transport and Lua
  handles. A job names the row it completes by id and generation; the
  pointers it carries (the transport, a timer's scheduler, the loaded
  configuration) belong to the client, whose adapter cancels every job before
  freeing it.
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
| `telar-core` | wire values shared by both processes, re-exporting `cellgrid` and `pacing` |
| `telar-backend` | the runtime: children, PTYs, emulation, agents, history, proxy |
| `model` | client state and its procedures, with no I/O, Lua or host access |
| `telar-client` | `Client` and the client flows: runtime socket, Lua VM, job queue, inbox |
| `telar-frontend` | the TUI adapter: host terminal, decoder, compositor, diff, pacing |
| `telar-gui` | the native adapter: glyph atlas and quads drawn by Metal or Vulkan |

Backend and client packages never import each other; both import core. The
TUI and GUI never import each other; what both embed lives in `assets`.

### Libraries

Mechanism that holds no telar state and decides no telar policy is a
library under `lib/<name>/`, with a `root.zig`, its own tests and its own
module named after the directory. A library imports only `std`, external
dependencies and other libraries; `build/Libraries.zig` registers it, makes it
importable from every package and fails the build if it imports anything
else. Consumers import the module once and alias its members
(`const gfx = @import("gfx");` then `const Rect = gfx.Rect;`).

| Library | Provides |
| --- | --- |
| `pty` | spawning a command on a pseudo-terminal, its environment, resize and exit |
| `pi_rpc` | a client for Pi's JSONL RPC mode, generic over who asked |
| `console` | the controlling terminal: raw mode, resize notifications, writer, escape sequences |
| `mailbox` | the bounded inbox between worker tasks and one consumer |
| `animate` | springs, transitions and the frame clock that advances them |
| `gfx` | rectangles, colors, quads and one-axis layout |
| `unicode` | grapheme widths from the emulator's tables; builds may bind another provider |
| `cellgrid` | cells, styles and buffers, and text laid out into them |
| `pacing` | the monotonic clock, replaceable deadlines and the frame pacer |

A rule that decides what telar means stays in a flow even when it is pure;
[`plans/libraries.md`](plans/libraries.md) lists what is still to move.
`src/main.zig` selects a CLI entrypoint.

The path a byte takes through one pane is drawn in [`AGENTS.md`](../AGENTS.md#one-pane-end-to-end).
