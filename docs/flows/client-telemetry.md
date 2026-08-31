# Client telemetry

Debug clients project their latest disposable state into one bounded JSON line
per diagnostics interval. This flow observes the client; it never commits
semantic model state, requests a draw or enters the interactive path.

## End-to-end path

```text
Client.init
    |
telemetry.State.init -> diagnostics.Sink
    |
telemetry.start
    |
ClientEvent.telemetry_tick <- diagnostics.waitForTick
    |
telemetry.handleTick
    +-- rearm next tick
    +-- capture immutable Snapshot
    +-- format into State.buffer
    +-- reserve one write token
    |
ClientEvent.telemetry_written <- diagnostics.Sink.write
    |
telemetry.handleWritten
    |
release token or finish deferred sink shutdown
```

`Client` owns one `telemetry.State`. That object owns the metrics epoch, the
diagnostics sink, the fixed 8192-byte line buffer and the single in-flight
write token. `run` starts the flow; `client_events` dispatches its two events.
Neither constructs file names, formats JSON or manages write lifetime.

## Snapshot boundary

`telemetry.capture` reads the active workspace, presenter pacing, retained
graphics bytes, host capabilities, Lua meter, outbox counters and heap
snapshot into a typed `Snapshot`. `format` accepts that snapshot together with
immutable metrics and pacer references through one `FormatRequest`.

The capture returns no value before the first active tab exists. Formatting is
bounded by the state-owned buffer and cannot allocate a replay queue. A format
error drops only that interval; the already-rearmed clock keeps later
observations alive.

Metrics record successful work at the component that performs it, but their
storage belongs to `telemetry.State`. The presenter borrows that metrics
address after the heap-stable `Client` has been initialized. Moving the client
or replacing the metrics object while it is live is therefore forbidden.

## Pacing, coalescence and failure

Every completed tick rearms the next one before capturing state. If a write is
already pending, the tick is folded into that future observation instead of
queuing obsolete JSON. At most one worker can borrow the buffer and sink.

The sink is fail-closed. A failed tick, failed rearm, failed write scheduling
or failed write disables later observations without affecting the client
loop. If the clock fails while a write still borrows the sink, `State` marks
the sink disabled but defers closing its file until that worker completes.
This prevents teardown of a resource still in use.

Client teardown first cancels every select task, then closes the sink. Release
builds and clients whose sink cannot be created schedule no telemetry work.
Neither condition changes semantic state or visible presentation.

## Proof

- `src/frontend/client/telemetry.zig` proves the bounded projection, one-write
  token, coalescence, deferred shutdown and write-failure recovery.
- `src/frontend/client/client_test.zig` proves a real substituted client
  schedules and completes a snapshot write without changing model or
  presenter versions, and that tick failure disables the sink.
- `src/frontend/client/client_events.zig` keeps telemetry events on the
  observation path and delegates both lifecycle boundaries to the telemetry
  adapter.
- `src/core/diagnostics.zig` owns the development-only sink, interval and heap
  attribution primitives shared with the runtime.
