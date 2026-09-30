# Limit reached

Telar keeps its memory fixed, so every table, buffer and queue has a limit.
When work asks for more than a limit allows, telar keeps what fits, drops the
excess and reports the limit by name. The user sees a notice such as
"bars.max_bar_actions: 17 click actions; limit 4", and
`telar diagnostics limits` lists every limit reached since the runtime
started. That list tells us which limit to raise. Nothing about reaching a
limit may close the window or stop the runtime.

## Reporting a limit

Declare the limit beside its constant with `core.Limit.declare`. The name is
the constant's stable identifier, the one the limits inventory uses. A name
that is not 1 to 64 bytes of letters, digits, `.`, `_` and `-`, or a noun
that is not up to 32 printable ASCII bytes, fails the build.

```zig
// src/model/bars/model.zig
pub const max_bar_actions = 4;
pub const bar_actions_limit = core.Limit.declare("bars.max_bar_actions", "click actions", max_bar_actions);
```

Then report at the place that enforces it, after keeping what fits.

In the runtime, with `model: *RuntimeModel`:

```zig
const limit_reached = @import("limit_reached.zig"); // src/backend/runtime

limit_reached.report(model, .{
    .limit = core.Limit.declare("session_checkpoint.snapshot_bytes", "bytes", model.checkpoint.snapshot_bytes),
    .requested = needed, // omit when the amount is unknown
});
```

In a client, with `client: *Client`:

```zig
const limit_reached = @import("../notifications/limit_reached.zig"); // src/client

limit_reached.report(client, .{
    .limit = data.bar_values.bar_actions_limit,
    .requested = actions,
});
```

The window and other adapters reach it through the `telar-client` module:
`client.limit_reached.report(gui.app, reach)`.

Both return `void`, never fail and allocate nothing. A model procedure that
has only `model: *ClientModel` returns its error and lets the client flow
that called it report, the same way it hands back any other effect.

The notice reads `<name>: <requested> <noun>; limit <value>`, or
`<name>: limit <value> <noun> reached` when `requested` is null.

### Which thread reports

`report` writes its process model, which only the thread that owns the
model may touch: the runtime's event loop, or the client adapter's loop. No
lock guards the table. A worker never reports. It returns the reach in its
completion, and the `finish` that runs on the loop reports it. No worker
reports a limit yet; this is the shape the first one takes, on worktree
detection, whose completion gains a `limit: ?core.LimitReach = null` field:

```zig
// The worker: a bounded scan that stopped at its limit.
fn detect(work: DetectionWork) WorktreeDetectionCompletion {
    var completion: WorktreeDetectionCompletion = .{ .pane = work.pane };
    if (scanned == max_scanned_entries) {
        completion.limit = .{
            .limit = core.Limit.declare("worktree_detection.max_scanned_entries", "directory entries", max_scanned_entries),
        };
    }

    return completion;
}

// On the event loop, where the completion arrives.
pub fn finish(model: *RuntimeModel, completion: WorktreeDetectionCompletion) !void {
    if (completion.limit) |reach| {
        limit_reached.report(model, reach);
    }
    // ...
}
```

That covers every worker the runtime starts with `select.concurrent`
(`observe`, `processMedia`, `ingestPane`, the checkpoint writer), the proxy,
history and plugin workers, and the client's jobs. A `LimitReach` borrows its
strings, so a completion carries names and nouns declared at comptime, which
live for the whole process.

A CLI command has no model and no window. When it reaches a limit it prints
the notice text to standard error (`reach.describe`) and exits with a
nonzero status. A library under `lib/` knows no telar limit names: it returns
its error, and the flow that called it, which has a model, maps the error to
its `Limit` and reports.

## End-to-end path

```text
flow enforcing a limit keeps what fits
  |
  +-- runtime: limit_reached.report(model, reach)
  |     core.limit_reached.record into model.limit_reaches: one probe
  |     shown in the last minute? -> only count
  |     else: log a `limits` warning, notifications.publish(warning notice)
  |             -> every UI client's toast
  |
  +-- client: client.limit_reached.report(client, reach)
        core.limit_reached.record into model.limit_reaches
        takeReport: at most once a second, report_limit{reach, hits}
          -> runtime limit_reached.receive -> model.client_limit_reaches
        shown in the last minute? -> only count
        else: log a `limits` warning, publishNotificationNow(warning notice)

telar diagnostics limits
  -> query_limits -> limit_reached.list -> PendingResponse.limit_list
  -> encoder reads both runtime tables when the reply is sent
  -> limit_list: evicted counts, refused reports, and one row per limit
     (name, noun, value, last amount, route, origin, hits, last time)
```

`core.LimitReaches` holds its rows and index and nothing else: 128 rows,
each found by its name's hash, with up to four keys per name so two names
whose hashes collide keep their own rows. A new limit in a full table
replaces the one reached longest ago and counts in `evicted`. What a reach
does to a row is `core.limit_reached.record`: count it, keep the last amount,
route and time, and decide whether to show it. Notices and reports are paced
by the monotonic clock; the time a reader sees is the wall clock.

The runtime keeps two tables. `model.limit_reaches` holds its own limits;
`model.client_limit_reaches` holds what clients report. A client that
reports a runtime limit's name, or a hundred invented names, never silences,
renames or evicts a runtime row, and never makes the runtime show a notice.
Each connection may send 32 reports a second; the rest are refused and
counted in `model.refused_limit_reports`. A request that stops at a limit
spends the same budget before it records a row or shows a notice, so a
client cannot flood the runtime's own table with oversized requests either.

A client reports to the runtime so one command lists both sides. A reach
inside the one-second report interval waits and rides on the next report,
and so does one that finds eight or fewer free outbox slots: a report never
takes the room pane input needs. The last reaches before a client goes quiet
stay in its own table and its headless dump until another reach sends them.

## Logs

The `limits` log scope is at `warn` in `main.zig`'s `std_options`; the
headless client keeps Zig's default level, which already shows warnings.
The launcher points a new background runtime's standard error at
`<socket>.runtime.start.log`, emptied by each launch and opened only as a
regular file the user owns with one link, without following a symlink or
blocking on a FIFO, so a runtime that fails before it holds the listener (a
configuration, graphics, history or proxy directory error) leaves its reason
there. Once it holds the listener it writes to `<socket>.runtime.log` in every
build. The runtime opens that file itself once it holds the listener
(`RuntimeLog.open` in `Resources.acquire`), so only the runtime that owns the
socket rotates it: a second launch that loses the race, or a retrying connect,
never moves a live runtime's log aside. The previous file stays as
`.runtime.log.1`, and the maintenance tick rotates a log that passes 1 MiB.
`telar diagnostics logs` reads both with the telemetry logs.

The runtime logs its own limits and each safety-net catch, with its route,
once per interval. It only counts what clients report, so a client cannot
grow the runtime's log. A client logs to its own standard error.

## Safety nets

A net catches exactly `core.limit_reached.LimitError`, the errors telar
raises when one of its own limits runs out. A flow that adds a limit error
adds it there, and `zig build codestyle` makes sure it does: every
`error.X` whose name contains `TooMany`, `TooLarge`, `TooLong`, `Full`,
`Exceeded`, `Exhausted`, `Limit`, `Capacity` or `Overflow` must be in
`LimitError`, `SystemError` or `NotLimitError`, each `NotLimitError` member
says why in a doc comment, and a `LimitError` member no file raises is an
error too.

`SystemError` holds what the host raises: memory from a real allocator, a
full disk (`NoSpaceLeft`) or disk quota, descriptor quotas and names the file
system refuses. A net logs those as errors with their route and lets them
keep their old path. `NoSpaceLeft` and `WriteFailed` are also what a fixed
buffer or writer returns when it overflows; since the two cannot be told
apart, neither is a limit error, and a flow that can overflow a fixed buffer
maps that to a named limit error. Any other error keeps its old path too, so
a net hides no host failure and no bug.

A fixed buffer or writer that overflows inside a runtime or window
handler is therefore not caught by any net: `bufPrint` returns
`NoSpaceLeft`, a fixed `std.Io.Writer` returns `WriteFailed`, and either
still ends `Runtime.run`. A flow that writes into one maps the overflow to a
named limit error where it writes, and reports that limit:

```zig
const text = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ label, value }) catch {
    limit_reached.report(model, .{ .limit = label_limit });
    return error.LabelTooLong; // in LimitError
};
```

A net reports the limit under the error's name
(`ChromeHitCapacityExceeded: limit reached`) with the route that caught it.
Once a flow reports its limit by name, the net no longer sees that error.

- `Runtime.update` runs each event through `dispatch`. A limit error skips
  that event through `limit_reached.absorb`; any other error still ends
  `Runtime.run`. `client_delivery.flush` has the same net.
- `client_connection.receive` passes a request's error to
  `limit_reached.refuse`. A limit error answers the request with
  `request_failed` and `resource_limit` and keeps the connection. A full
  response queue is the slow-client policy and still drops the client, also
  when the reply an event owes does not fit (`dropUnanswered`).
- `GuiAdapter.update` absorbs a limit error per event and per step of the
  turn, so the rest of the batch, `reconcileFocus` and the presentation
  still run. `pump` keeps a second net: the same error twice asks for no
  draw.
- A runtime message that stops at a limit while the client applies it
  (`runtime_io.receiveRuntime`) is recovered from. The client reads which
  resync the message needs (`limit_reached.plan`), re-arms its read before
  anything else can fail, and `limit_reached.recover` reports the limit and
  asks for the smallest resync the protocol has:
  - a graphics message: the store paused that pane's stream at the limit
    (`awaiting_snapshot`), so the chunks and placements of an image that
    did not fit are dropped instead of failing as unknown, and a graphics
    snapshot resumes the pane;
  - a pane frame: a snapshot of that pane;
  - anything else: a new session, which rebuilds the replica.

  A resync the client cannot ask for, such as a full outbox, loses the link,
  so the replica never stays wrong while the link shows connected. More
  than three resyncs within a minute stop asking: a pane's graphics stay
  paused until a later snapshot, and any other resync gives the link up
  (`runtime_link.abandon`) with the limit's name and no retry, since each
  would stop at the same limit. Retrying by hand counts anew. An error after
  the message was applied, in the adapter, never resyncs.
- The window's `render` callback passes draw errors to the GUI's
  `limit_reached.absorbFrame`. Draw returns token 0, and both native
  backends keep the last presented frame. `GuiAdapter.limited` holds the
  observation and viewport that stopped, and the window neither measures nor
  prepares that frame again until one of them changes. Because a frame that
  keeps failing cannot show its own notice, the window title ends with
  " — limit reached: <name>" until a frame draws, and the frame that draws
  wakes the loop so the title drops it. Errors the window raises
  itself are named (`render.retained_max_cells`, `protocol.max_cell_count`,
  `render.frame_quad_budget`, `gui.widgets.registry_capacity`,
  `text.glyph_atlas_side`).
- A session larger than `session_checkpoint.snapshot_bytes` writes the
  prefix of records that fits. Records point back to earlier records, tabs to
  their workspace and panes to their tab, so the prefix restores cleanly.
  `session_checkpoint.start` never fails: a write it cannot encode or start
  is logged and counted.

### Order inside a handler

A net that skips the rest of a handler must not skip what keeps its source
alive. A handler re-arms its timer or read, clears its in-flight flag and
releases its slot before any step that can fail, or keeps that step's error
and returns it at the end:

```zig
// pane_observation.finish
const draft = agent_control.clearRestoredDraft(model, pane);
reconcileScreen(model, pane, completion.stats, transition.shell_foreground);
agent_hooks.answerParked(model, completion.pane);
const next = start(model, pane); // re-arms the observation
try draft;
try next;
```

`pane_output.receive`, `worktree_detection.finish` and
`client_delivery.flush` follow the same rule.

## Client diagnostic

The reason the last bar, panel, pick or action failed is the client
diagnostic ([Client diagnostic state](client-diagnostic.md)). The window
draws it as a red chip at the right of the status bar, which a press
dismisses and a screen reader reads, and a failed panel says
"Could not update: <reason>". The headless dump has it under `diagnostic`,
with notice levels and the client's `limits`.

## Validation

- `src/core/LimitReaches.zig`: replacement of the oldest row, the evicted
  count and names whose keys collide.
- `src/core/limit_reached.zig`: the error classes, one notice per interval,
  counting, report folding and unnamed reaches.
- `src/core/schema/messages/limits.zig` and the golden corpus:
  `report_limit`, `query_limits` and `limit_list`.
- `src/backend/runtime/tests/limit_reached_test.zig`: the runtime notice,
  client reports kept apart, a client that cannot silence or evict runtime
  rows, the report rate, a refused request that keeps its connection, the
  update net, and `Runtime.update` skipping a real event.
- `checkpoint_shutdown_test.zig`: a session larger than its checkpoint keeps
  the runtime and restores cleanly.
- `src/backend/runtime/resources/RuntimeLog.zig`: rotation at start and past
  the size bound.
- `client_tests.recoverLimitedMessages`, run from
  `src/client/notifications/limit_reached.zig`: the graphics and pane
  snapshots, a new session, a resync a full outbox cannot ask for, the
  budget that keeps graphics paused and gives the link up naming the limit,
  and a manual retry that counts anew.
- `src/client/graphics/tests.zig`: an image or a chunk past its limit pauses
  the pane's stream, whose chunks and placements are then dropped, and a
  snapshot resumes it.
- `src/client_tests/limit_reached.zig` and `configuration.zig`: the client
  notice, folded reports, the adapter net, a real bar of five click actions
  and a failing panel, and the diagnostics their next render clears.
- `src/gui/tests/limit_reached.zig`: a frame stopped at the cell budget
  through the native callbacks keeps the window open, names the limit in the
  title and draws again; an update event at a limit is skipped while the
  rest of the turn runs.
- `src/cli/integration/limits.test.mjs`: against a built telar, a client
  reports a limit over the socket, `telar diagnostics limits` lists it and
  the background runtime writes its own log.
