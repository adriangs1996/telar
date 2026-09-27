# Client telemetry

The periodic client telemetry line left with the terminal client. That client
armed a diagnostics tick, captured a bounded snapshot and wrote one JSON line
per interval to its sink. Neither the window nor the headless client schedules
that tick, so no client flow writes telemetry lines today.

## What remains

`Client` still owns one `TelemetryState` (`client.telemetry`, in
`src/client/resources/TelemetryState.zig`). It holds the metrics epoch, the
`Metrics` counters, the fail-closed `core.Sink`, a fixed 8192-byte line buffer
and a single write flag. In builds with diagnostics enabled and a runtime
endpoint, `TelemetryState.init` creates the sink file
`<endpoint>.client-<pid>.log` with mode `0600`. Release builds create nothing.
`Client.deinit` closes the sink through `TelemetryState.deinit`.

Shared components still count their work in `client.telemetry.metrics`: for
example `runtime_io` calls `TelemetryState.recordMessage` for every decoded
runtime message, `pointer_routing.apply` counts pointer events, and
`GuiAdapter.drainInput` adds physical-key lease overflows. The counters never
commit semantic model state, request a draw or enter the interactive path.

The window measures itself through `core.profiling` counters instead, and the
headless client writes its own trace (see [Headless client](headless-client.md)).
`src/core/diagnostics.zig` and `src/core/Sink.zig` still own the
development-only sink, interval and heap attribution primitives shared with
the runtime.
