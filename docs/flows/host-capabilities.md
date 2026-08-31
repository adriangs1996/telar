# Host capabilities

Each client negotiates the features of its own exterior terminal. The result is
disposable client state. It never becomes runtime truth, because two clients
attached to the same runtime may use different terminals.

## End-to-end paths

```text
APC or CSI reply
       |
presentation input parser
       |
InputHandler.terminalResponse
       |
host_capabilities.observe
       |
protocol reply translation
       |
HostCapabilities.Handler.observe
       |
ClientModel.observeHostCapability
       |
resource synchronization
       |
presentation_lifecycle.observe
       |
Presenter
```

```text
250 ms probe deadline
       |
host_capabilities.handleExpiry
       |
HostCapabilities.Handler.expire
       |
ClientModel.expireHostCapabilities
       |
fallback resource synchronization
       |
presentation_lifecycle.observe
       |
Presenter
```

The protocol adapter recognizes the two reserved Kitty image IDs, window and
cell pixel reports, and mode 1016 support. It converts them into
`HostCapabilityObservation`, which contains no parser or terminal-protocol
types. An unrelated Kitty image ID and primary device attributes are no-ops.

## Model transaction

`ClientModel` owns `HostCapabilities`. It stores independent support states for
Kitty graphics, Kitty zlib and pixel mouse coordinates, plus the latest raw
window and cell pixel measurements. Each support state starts as `unknown`.
The deadline changes only values that are still unknown to `unsupported`.

A recognized response computes the complete next capability value before it
mutates the model. Pixel observations also resolve the next
`schema.TerminalSize`. Explicit cell pixels take precedence over dimensions
derived from window pixels and the current grid.

`ClientModel.reconcileHost` validates the resolved geometry first, then commits
capabilities and geometry as one `HostCommit`. An invalid or oversized grid
or a geometry inconsistent with its raw measurements changes neither value.
Capability changes advance `Version.host_capabilities`; geometry changes
independently advance `Version.host`. Exact repeats advance neither version and
run no effects.

Platform resize measurements use the same `HostUpdate`. This keeps raw window
pixels and the geometry derived from them in one model transaction.

## Effects and consumers

The application handler calls its effect port only after the complete model
commit. A Kitty graphics transition enters
`SyncPaneGraphicsFallbacksHandler`, which reads that committed capability,
reconciles every bounded pane cell fallback, and leaves physical-presence
queries to the graphics adapter. The host adapter then configures sidebar and
overlay resources and invalidates physical placements. A geometry transition
delegates screen, view and pane-size synchronization to the host resize
adapter.

Kitty zlib needs no immediate resource mutation. The media presenter reads the
committed value before transmission. Pixel mouse support is also effect-free;
the input adapter reads it when encoding the next mouse event. Configuration
validation, telemetry and pane-graphics policy all read immutable capability
values from `ClientModel`.

A failed sidebar configuration or geometry effect does not restore older
capabilities. The client session terminates with the committed disposable
state, while runtime panes continue and a reconnect negotiates a fresh model.

## Presentation

Neither the response adapter nor the timeout requests a draw or advances
disposable presentation ingress. `client_events` publishes the resulting model
version. The presenter folds a changed version into its paced frame and records
the version it painted. A repeated reply or deadline on an already settled
model schedules no frame.

`client_startup` registers the deadline through
`host_capabilities.scheduleExpiry` after the runtime handshake.
`host_capabilities.handleExpiry` validates its completion before applying the
fallback, so a failed timer changes no capability state.

## Proof

- `src/frontend/client/model.zig` proves independent probes, selective expiry,
  pixel precedence, atomic geometry and validation before mutation.
- `src/frontend/client/application/host_capabilities.zig` proves
  commit-before-effect ordering, no-op suppression and retained commits after
  an effect failure.
- `src/frontend/client/application/pane_graphics.zig` proves capability-owned
  fallback decisions, bounded traversal and repeated-value suppression.
- `src/frontend/client/host_capabilities.zig` owns terminal reply translation,
  probe expiry and resource projection.
- `src/frontend/client/client_test.zig` proves fallback reconciliation,
  presenter-owned scheduling, timeout idempotence and retained state after a
  real resource failure.
