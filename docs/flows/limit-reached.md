# Limit reached

Telar keeps its memory fixed, so every table, buffer and queue has a limit.
When work asks for more than a limit allows, telar keeps what fits, drops the
excess and reports the limit by name. The user sees a notice such as
"bars.max_bar_actions: 17 click actions; limit 4", and
`telar diagnostics limits` lists every limit reached since the runtime
started. That list tells us which limit to raise. Nothing about reaching a
limit may close the window or stop the runtime.

## Reporting a limit

Declare the limit where its constant lives. The name is the constant's
stable identifier, the one the limits inventory uses.

```zig
// src/model/bars/model.zig
pub const max_bar_actions = 4;
```

Then report at the place that enforces it, after keeping what fits.

In the runtime, with `model: *RuntimeModel`:

```zig
const limit_reached = @import("limit_reached.zig"); // src/backend/runtime

limit_reached.report(model, .{
    .limit = .{
        .name = "session_checkpoint.snapshot_bytes",
        .noun = "bytes",
        .value = model.checkpoint.snapshot_bytes,
    },
    .requested = needed, // omit when the amount is unknown
});
```

In a client, with `client: *Client`. The window and other adapters call
`client.limit_reached.report(gui.app, reach)` through the `telar-client`
module.

```zig
const limit_reached = @import("../notifications/limit_reached.zig"); // src/client
const data = @import("model");

limit_reached.report(client, .{
    .limit = .{
        .name = "bars.max_bar_actions",
        .noun = "click actions",
        .value = data.bar_values.max_bar_actions,
    },
    .requested = actions,
});
```

Both return `void`. They never fail and allocate nothing. A model procedure
that has only `model: *ClientModel` returns its error and lets the client
flow that called it report, the same way it hands back any other effect.

The notice reads `<name>: <requested> <noun>; limit <value>`, or
`<name>: limit <value> <noun> reached` when `requested` is null. A name holds
at most 64 bytes of letters, digits, `.`, `_` and `-`; a noun at most 32
printable ASCII bytes (`core.Limit.validate`).

## End-to-end path

```text
flow enforcing a limit keeps what fits
  |
  +-- runtime: limit_reached.report(model, reach)
  |     LimitReaches.record: one hash probe, count, last amount, last time
  |     shown in the last minute? -> only count
  |     else: log `limits` warn line, notifications.publish(warning notice)
  |             -> every UI client's toast
  |
  +-- client: client.limit_reached.report(client, reach)
        LimitReaches.record in model.limit_reaches
        takeReport: at most once a second, report_limit{reach, hits}
          -> runtime limit_reached.receive -> counted with origin client
        shown in the last minute? -> only count
        else: log `limits` warn line, publishNotificationNow(warning notice)

telar diagnostics limits
  -> query_limits -> limit_reached.list -> PendingResponse.limit_list
  -> encoder reads model.limit_reaches when the reply is sent
  -> limit_list (every row: name, noun, value, last amount, origin, hits, last time)
```

`core.LimitReaches` is one table used by both processes: 64 rows, an
open-addressed index keyed by the name's hash, columns for the last amount,
hits, last and shown times, and the reaches a client has not reported yet. A
65th limit replaces the one reached longest ago; that scan runs only when a
new name arrives with the table full. The runtime's table lives in
`RuntimeModel.limit_reaches`, a client's in `ClientModel.limit_reaches`.

A client reports what it reached to the runtime so one command lists both
sides. A reach inside the one-second report interval waits and rides on the
next report, and so does one that finds fewer than eight free outbox slots:
a report never takes the room pane input needs. The last reaches before a client goes quiet stay in its own
table and its headless dump until another reach sends them.

## Logs

The `limits` log scope is at `warn` in `std_options`. The background
runtime's standard error is `<socket>.runtime.log` in every build; the
runtime that ran before it keeps its lines in `<socket>.runtime.log.1`
(`ServerLaunch.launchDaemon`). `telar diagnostics logs` reads that file with
the telemetry logs. The runtime logs its own limits and every safety-net
catch. It only counts what clients report, so a client cannot grow the
runtime's log. A client logs to its own standard error.

## Safety nets

A net is for limits nobody named yet. It reports the limit under the error's
name (`ChromeHitCapacityExceeded: limit reached`) and logs the route with the
notice, so a limit reached every frame writes two lines a minute. Once a
flow reports its limit by name, the net no longer sees that error.

- `Runtime.update` runs each event through `dispatch`. A capacity error skips
  that event through `limit_reached.absorb`; any other error still ends
  `Runtime.run`. `client_delivery.flush` has the same net.
- `client_connection.receive` passes a request's error to
  `limit_reached.refuse`. A capacity error answers the request with
  `request_failed` and `resource_limit` and keeps the connection. A full
  response queue still drops the client, because that is the slow-client
  policy and not a limit.
- The window's `render` and `pump` callbacks pass errors to the GUI's
  `limit_reached.absorb`. Draw returns token 0, and both native backends
  then keep the last presented frame. `GuiAdapter.limited` holds the
  observation and the viewport that stopped, and the window neither
  measures nor prepares that frame again until one of them changes. Errors the window raises itself are named
  (`render.retained_max_cells`, `protocol.max_cell_count`,
  `render.frame_quad_budget`, `gui.widgets.registry_capacity`,
  `text.glyph_atlas_side`). A failed update loses only the event that failed;
  the rest of the batch stays queued.
- A session larger than `session_checkpoint.snapshot_bytes` writes the
  prefix of records that fits. Records point back to earlier records, tabs to
  their workspace and panes to their tab, so the prefix restores cleanly. The
  runtime reports the limit instead of stopping and killing every pane.

A frame that keeps failing cannot show its own notice, since the notice is
part of the frame. The limit still reaches the log and
`telar diagnostics limits`.

## Client diagnostic

The reason the last bar, panel, pick or action failed is the client
diagnostic (`docs/flows/client-diagnostic.md`). The window draws it as a red
chip at the right of the status bar, and a failed panel says
"Could not update: <reason>". The headless dump has it under `diagnostic`,
with notice levels and the client's `limits`.

## Validation

- `src/core/LimitReaches.zig` proves one notice per interval, that every
  reach counts, report folding and replacement of the oldest row.
- `src/core/schema/messages/limits.zig` and the golden corpus cover
  `report_limit`, `query_limits` and `limit_list`.
- `src/backend/runtime/tests/limit_reached_test.zig` covers the runtime
  notice, dedup and count, client reports in the list, a refused request that
  keeps its connection, and the update net.
- `checkpoint_shutdown_test.zig` writes a session larger than its checkpoint,
  keeps the runtime and restores cleanly.
- `src/client_tests/limit_reached.zig` covers the client notice, dedup,
  count, folded reports and the adapter net.
- `src/gui/tests/limit_reached.zig` stops a frame at the cell budget through
  the native callbacks: the window stays open, token 0 keeps the last frame,
  the notice is shown once and a later frame draws.
- `src/headless/dump.zig` and `src/cli/diagnostics.zig` prove what the dump
  and `telar diagnostics limits` print.
