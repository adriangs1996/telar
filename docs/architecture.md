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
  which the client integration harness (`src/client_tests`) runs after every
  settled step and the model's
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

`Client` has no other behavior than `init`, `deinit`, `update`, `flush`,
`failJob` and `failBackgroundJob`. Client procedures live in flow files under `src/client`: one that
touches only the model takes `model: *ClientModel`; one that also reaches the
transport, Lua, the clock or the job queue takes `client: *Client`.

After the switch, the process flushes once. The runtime delivers pending
output to every affected client in a single pass. The client's adapter calls
`Client.flush`, which writes what the event left in `model.to_runtime`, then
starts the jobs the event queued; the presenter compares revisions once and
schedules presentation.

## The host boundary is data

The native GUI (`GuiAdapter`), the headless client (`HeadlessClient`) and the
headless test adapter are presentation adapters. Each owns its host
resources: window, renderer, output buffers, pacing. Each embeds one
`Client` and drains it after every event.

- The adapter writes host facts into `model.host` before calling `update`.
- Procedures push host requests (write the clipboard, show a notice on the
  outer terminal, capture clipboard media) into `model.to_host`. The adapter
  drains it with an exhaustive switch. A host without a feature writes that
  branch as an empty arm, visible in one line.
- Procedures push runtime messages into `model.to_runtime`; `flush` writes
  them once per event.
- Procedures start workers by pushing a `client.Job` into
  `client.to_workers`, or a `client.BackgroundJob` into
  `client.to_background`. A `Job` is interactive work of a few words (a
  runtime read or write, a timer); a `BackgroundJob` carries its own copy of
  a request, kilobytes, so it queues apart and a runtime read never copies
  it. The adapter drains both queues until they are empty, starts each job
  off the event loop and the job reports through its completion message. A
  job the adapter cannot start finishes through `Client.failJob` (or
  `failBackgroundJob`) as that same completion carrying the error, so one
  handler releases what starting it reserved. The queues live in `Client`,
  not the model, because jobs carry transport and Lua handles. A job names the row it completes by id and generation; the
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
| `telar-core` | wire values shared by both processes |
| `telar-backend` | the runtime: children, PTYs, emulation, agents, history, proxy |
| `model` | client state and its procedures, with no I/O, Lua or host access |
| `telar-client` | `Client` and the client flows: runtime socket, Lua VM, job queue, inbox |
| `telar-gui` | the native adapter: glyph atlas and quads drawn by Metal or Vulkan |
| `telar-headless` | the headless client for tests and tools: stdin input, exit trace and dump |

Backend and client packages never import each other; both import core. The
GUI and the headless client never import each other; what adapters embed
lives in `assets`.

### Libraries

Mechanism that holds no telar state and decides no telar policy is a
library under `lib/<name>/`, with a `root.zig`, its own tests and its own
module named after the directory. A library imports only `std`, external
dependencies and other libraries; `build/Libraries.zig` registers it, makes it
importable from every package and fails the build if it imports anything
else. Consumers import the module once and alias its members
(`const gfx = @import("gfx");` then `const Rect = gfx.Rect;`). A package
depends on a library by importing it, never through another package: no
file outside `lib/` declares `pub const X = library.member`, and
`zig build check-library-reexports` rejects one. The model imports only the
libraries `build/model.zig` lists, pure values and deadlines.

| Library | Provides |
| --- | --- |
| `pty` | spawning a command on a pseudo-terminal, its environment, resize and exit |
| `pi_rpc` | a client for Pi's JSONL RPC mode, generic over who asked |
| `console` | the controlling terminal: raw mode, resize notifications, writer, escape sequences, a screen that sends only changed cells, and decoding the keys, mouse reports and replies it sends |
| `mailbox` | the bounded inbox between worker tasks and one consumer |
| `animate` | springs, transitions and the frame clock that advances them |
| `gfx` | rectangles, colors, quads, the quad list a frame is built in, and one-axis layout |
| `unicode` | grapheme widths from the emulator's tables; builds may bind another provider |
| `cellgrid` | cells, styles and buffers, text laid out into them, damage rows and run diffing, selection by character, word or line |
| `pacing` | the monotonic clock, replaceable deadlines and the frame pacer |
| `vtscan` | byte-at-a-time scanners for OSC strings, typed input and Kitty graphics framing |
| `sqlite` | the one SQLite binding, statement helpers, additive migrations, FTS5 quoting |
| `imaging` | PNG through Wuffs with limits checked first, ICO frames, box-filter and bilinear resampling |
| `hostmetrics` | cpu, memory and battery of the host; nothing is kept between samples |
| `gitstatus` | a working tree's branch and whether it has changes |
| `localsocket` | same-user Unix sockets and length-prefixed framing |
| `bytecodec` | bounds-checked little-endian encoding into caller buffers and decoding from borrowed bytes |
| `urlscan` | classifying a URI by scheme, finding the URI or the local file path under an offset in a line, and the line and column a link points at |
| `keyinput` | keys, characters, modifiers and mouse events as values, chord parsing, binding order, bounded bindings and physical-key leases |
| `textraster` | text shaped and rasterized into RGBA with FreeType and HarfBuzz in a caller's font, and rounded fills |
| `syntaxhl` | syntax roles, languages by file path, Tree-sitter captures as roles, and a bounded highlighting cache keyed by content |
| `textfield` | a fixed-capacity single-line text field: byte offsets, grapheme-cluster movement, directed selection and a view scrolled to fit |
| `kitty_protocol` | Kitty graphics transmission, placement and deletion commands written into a caller buffer, the image format, and received control fields |
| `cellglyphs` | box drawing, block elements and Braille painted from geometry into a quad list |
| `mdinline` | inline Markdown spans over borrowed text and bounded link destination decoding |
| `cellcodec` | runs of cells with a packed header, styles written on change and colors sized by kind |
| `agentfiles` | titles from Claude Code's JSONL transcript and Codex's thread database |
| `editorremote` | reusing a terminal editor: identify it, reach its server, open a literal path at a line; the argv that launches a new one there |
| `vtgrid` | a ghostty-vt terminal as cells: render state onto a `cellgrid` buffer, damaged rows into cost-aware spans, incremental scrollback search |
| `cmdcapture` | commands, directories, exit status and output tails read from a pane's terminal |
| `jsonl` | bounded JSON-lines streams, in-place truncation of output fields, total value accessors |
| `h2frames` | HTTP/2 frames, SETTINGS, header blocks and stream states, without a connection |
| `localca` | a local certificate authority, per-host leaves, system roots and intercepted TLS sessions |
| `httprelay` | HTTP/1.1 and HTTP/2 relays that forward bytes unchanged and report what they forwarded |
| `dropqueue` | a bounded many-publisher queue that drops instead of waiting and counts depth, high water and loss |
| `exchangecapture` | bounded capture of relayed exchanges: heads and de-framed bodies within a shared quota, halves paired by key, bodies decoded |
| `touchtrace` | client requests that mark byte ranges and code windows for the touchrange Valgrind tool; no-ops natively |

A rule that decides what telar means stays in a flow even when it is pure;
[`plans/libraries.md`](plans/libraries.md) lists what is still to move.
`src/main.zig` selects a CLI entrypoint.

The path a byte takes through one pane is drawn in [`AGENTS.md`](../AGENTS.md#one-pane-end-to-end).
