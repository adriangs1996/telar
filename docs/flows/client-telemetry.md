# Client telemetry

In builds with diagnostics, every client (the window's and the headless one)
projects its counters and its disposable state into one bounded JSON line
once a second and appends it to `<endpoint>.client-<pid>.log`, which
`telar diagnostics logs --component client` reads. This flow observes the
client; it never commits semantic model state, requests a draw or enters the
interactive path.

## End-to-end path

```text
Client.init
    |
TelemetryState.init -> core.Sink (fail-closed; nothing in release builds)
    |
client_telemetry.start -> Job.telemetry_tick
    |
Message.telemetry_tick <- core.waitForTick
    |
client_telemetry.finishTick
    +-- rearm the next tick
    +-- capture the client state
    +-- format into TelemetryState.buffer
    +-- reserve the one write token
    |
Job.telemetry_write -> Message.telemetry_written <- Sink.write
    |
client_telemetry.finishWrite -> TelemetryState.finishWrite
    |
release the token, or finish a deferred sink shutdown
```

`Client` owns one `TelemetryState` (`client.telemetry`): the metrics epoch,
the `Metrics` counters, the sink, a fixed 8192-byte line buffer and the single
in-flight write token. Both jobs run through `job_runner` like every other
client job, so each adapter starts them without knowing what they do, and
both messages run on the observation budget.

## What a line holds

`client_telemetry.capture` copies the active tab, tab and pane counts, the
focused pane, theme name, outbox counters, cell size and the Lua
meter; `format` adds the counters components record in `Metrics` (input
events and bytes, key lease overflows, pointer events, runtime messages and
bytes, graphics messages and images, applied frames, cells, spans and
snapshots, decode, apply and input-enqueue timings) and the process RSS.
Formatting is bounded by the state-owned buffer; a format error drops only
that interval.

Components count successful work where they perform it: `runtime_io` calls
`TelemetryState.recordMessage` for every decoded runtime message,
`pane_frames` counts applied frames, `pane_input` counts input, `pointer_routing` counts pointer
events and `GuiAdapter.drainInput` adds physical-key lease overflows.

## Pacing, coalescence and failure

Every completed tick rearms the next one before capturing state. A tick that
finds a write in flight folds into the next observation instead of queuing an
obsolete line, so at most one worker borrows the buffer and the sink.

The sink is fail-closed. A failed tick, a failed rearm or a failed write
disables later observations without affecting the client loop. If the tick
fails while a write still borrows the sink, `TelemetryState.disable` marks it
disabled and `finishWrite` closes the file once that write completes. Clients
whose sink cannot be created, and release builds, schedule no telemetry work.
Adapters cancel their jobs before `Client.deinit` closes the sink.

## Where the lines go

The runtime writes `<endpoint>.runtime-<pid>.log` the same way, once a
second. Both go through `core.Sink`, which bounds them: a file that would
pass `Sink.max_file_bytes` (4 MiB, about 17 minutes of runtime lines)
becomes `<name>.log.1`, replacing the previous one, and writing restarts
in an empty file, so a process keeps at most 8 MiB. A failed rotation
retires the sink like any failed write. When a runtime or a client starts,
`Sink.removeOrphans` removes, from the socket's directory, the
`<endpoint>.runtime-<pid>.log` and `<endpoint>.client-<pid>.log` (and their
`.1`) whose process no longer runs, when the endpoint is this one or its
name ends in `.sock`, so a socket in a directory of other files never
removes a file telar did not write; release builds, which write no lines, clean up
too. `telar diagnostics logs` reads the current files, not the `.1`.

## Validation

- `src/client/resources/client_telemetry.zig` proves the bounded line.
- `src/core/Sink.zig` proves rotation into one previous generation and
  that cleanup removes the logs of ended processes and keeps the rest;
  `src/core/DiagnosticLogName.zig` the names it recognizes.
- `src/client/resources/TelemetryState.zig` proves the one write token,
  deferred shutdown and write-failure recovery, and that a client without an
  endpoint stays disabled.
- `client telemetry writes one snapshot without mutating semantic state` in
  `src/client_tests/renaming_and_telemetry.zig` drives the flow through
  `Client.update`: a tick queues the next tick and one write, a tick during
  the write folds, the write appends exactly one line to the sink without
  changing the model version, and a failed tick disables the sink.
