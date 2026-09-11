# Host capabilities

Each client negotiates the features of its own exterior terminal. The result is
disposable client state. Graphics and mouse support never become runtime truth,
because two clients may use different terminals. Known default colors are sent
as per-client values; the geometry owner supplies each pane's defaults. See
[terminal colors](terminal-colors.md).

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
DeliverHostResourcesHandler
       |
physical host effects
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
DeliverHostResourcesHandler
       |
fallback host effects
       |
presentation_lifecycle.observe
       |
Presenter
```

The protocol adapter recognizes the two reserved Kitty image IDs, window and
cell pixel reports, mode 1016 support, and OSC 10/11 color reports. RGB values
remain in the model; the background also resolves light or dark appearance by
luminance. When the
appearance changes and `client.appearance` configures a theme for it, the
delivery handler swaps the view theme unless `--theme` locked it; the same
preference applies when a configuration generation is adopted. The
colors are queried at startup and refreshed with pixel probes on host resize,
without overlapping color-query windows. The adapter converts replies into
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

The capability handler delivers its `HostCommit` only after the complete model
transition. `DeliverHostResourcesHandler` validates that the commit is still
current and owns every branch shared with host resizing. A Kitty graphics
transition enters
`SyncPaneGraphicsFallbacksHandler`, which reads that committed capability,
reconciles every bounded pane cell fallback, and leaves physical-presence
queries to the graphics adapter. The shared host adapter then configures
sidebar and overlay resources and invalidates physical placements. A geometry
transition executes the same ordered screen, view and pane-size effects without
depending on the host-resize adapter.

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

`client_startup` begins negotiation through `host_capabilities.begin` before
subscribing to runtime state. The same adapter refreshes queries on resize and
owns a single replaceable deadline through `host_capabilities.scheduleExpiry`.
`host_capabilities.handleExpiry` validates its completion before applying the
fallback, so a failed timer changes no capability state.

## Proof

- `src/client/model/Model.zig` proves independent probes, selective expiry,
  pixel precedence, atomic geometry and validation before mutation.
- `src/client/application/host/host_capabilities.zig` proves
  commit-before-delivery ordering, no-op suppression and retained commits after
  a delivery failure.
- `src/client/application/host/host_resource_delivery.zig` proves graphics,
  grid, cell-size and geometry branch ordering plus partial-failure behavior.
- `src/client/application/panes/pane_graphics.zig` proves capability-owned
  fallback decisions, bounded traversal and repeated-value suppression.
- `src/frontend/client/controllers/host/host_capabilities.zig` owns terminal reply translation
  and probe expiry.
- `src/frontend/client/controllers/host/host_resources.zig` implements the physical host effect
  ports shared with resize delivery.
- `src/frontend/client/tests/` proves fallback reconciliation,
  presenter-owned scheduling, timeout idempotence and retained state after a
  real resource failure.
