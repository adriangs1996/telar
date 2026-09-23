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
host_inputs.terminalResponse
       |
host_capabilities.observe
       |
host_capabilities.translate
       |
host_capabilities.observeHostCapability
       |
ClientModel.observeHostCapability
       |
host_resize.deliverHostCommit
       |
view_chrome.refresh and host_effects.deliver
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
host_capabilities.reconcileHostCapabilities
       |
host_resize.applyHostUpdate
       |
ClientModel.reconcileHost
       |
host_resize.deliverHostCommit
       |
view_chrome.refresh and host_effects.deliver
       |
presentation_lifecycle.observe
       |
Presenter
```

The protocol adapter recognizes the two reserved Kitty image IDs, window and
cell pixel reports, mode 1016 support, and OSC 10/11 color reports. RGB values
remain in the model; the background also resolves light or dark appearance by
luminance. When the
appearance changes and `client.appearance` configures a theme for it,
`host_resize.deliverHostCommit` writes `model.theme` unless `--theme` locked
it, and `view_chrome.refresh` hands it to the view; the same preference applies
when a configuration generation is adopted. The
colors are queried at startup and refreshed with pixel probes on host resize,
without overlapping color-query windows. The adapter converts replies into
`HostCapabilityObservation`, which contains no parser or terminal-protocol
types. An unrelated Kitty image ID and primary device attributes are no-ops.

## Model transaction

`ClientModel` owns `HostCapabilities` in `model.host`. It stores independent
support states for Kitty graphics and pixel mouse coordinates, plus the latest
raw window and cell pixel measurements. Each support state starts as `unknown`.
The deadline, through `host_negotiation.settledCapabilities`, changes only
values that are still unknown to `unsupported`. Kitty zlib support is TUI
state: `host_capabilities.observe` records it in `terminal.host_negotiation`
and the graphics store and never revises the model.

A recognized response computes the complete next capability value before it
mutates the model. Pixel observations also resolve the next
`core.TerminalSize`. Explicit cell pixels take precedence over dimensions
derived from window pixels and the current grid.

`ClientModel.reconcileHost` validates the resolved geometry first, then commits
capabilities and geometry as one `HostCommit`. An invalid or oversized grid
or a geometry inconsistent with its raw measurements changes neither value.
Capability changes advance `Version.host_capabilities`; geometry changes
independently advance `Version.host` (`model.host.host_capabilities_revision`
and `model.host.host_revision`). Exact repeats advance neither version and
run no effects.

Platform resize measurements use the same `HostUpdate` through
`host_resize.applyHostUpdate`. This keeps raw window
pixels and the geometry derived from them in one model transaction.

## Effects and consumers

`host_capabilities.observeHostCapability` and `reconcileHostCapabilities` deliver a `HostCommit` only after the
complete model transition. The private `host_resize.deliverHostCommit` validates that the commit is still
current and owns every branch shared with host resizing. Changed terminal
colors are queued to the runtime as `configure_terminal_colors` once startup
is opening. A Kitty graphics transition calls `pane_graphics.syncFallbacks`,
which reads the committed capability from the model and queries the client's
graphics retention while reconciling each bounded pane cell fallback, then sets
`model.to_host.invalidate_placements`. A geometry transition runs the same
pane-size branch as a host resize.

After the event, `view_chrome.refresh` compares the host, capability,
configuration and chrome revisions with the ones it last followed, resizes the
presenter and view, and configures sidebar resources for the committed image
support and cell size. `host_effects.deliver` drains `model.to_host` and
invalidates physical placements.

Kitty zlib needs no immediate resource mutation. The media presenter reads the
adapter's value before transmission. Pixel mouse support is also effect-free;
`pointer_routing` and `tab_drag` read it when they convert the next mouse
event. Configuration
validation, telemetry and pane-graphics policy all read immutable capability
values from `ClientModel`.

A failed sidebar configuration or geometry effect does not restore older
capabilities. `view_chrome.refresh` leaves its revisions unobserved and the
error leaves the event with the committed disposable state; runtime panes
continue and a reconnect negotiates a fresh model.

## Presentation

Neither the response adapter nor the timeout requests a draw or advances
disposable presentation ingress. `events.update` calls
`presentation_lifecycle.observe` once per inbox turn to publish the resulting
model version. The presenter folds a changed version into its paced frame and records
the version it painted. A repeated reply or deadline on an already settled
model schedules no frame.

`client_startup.start` begins negotiation through `host_capabilities.begin`
before it starts the runtime read; `client_startup.advance` sends the bootstrap
once the initial probes settle. The same adapter refreshes queries on resize and
owns a single replaceable deadline through `host_capabilities.scheduleExpiry`.
`host_capabilities.handleExpiry` validates its completion before applying the
fallback, so a failed timer changes no capability state.

## Validation

- `src/model/state/tests/configuration_and_host.zig` proves independent probes, selective expiry,
  pixel precedence, atomic geometry and validation before mutation.
- `src/frontend/client/tests/host_resources.zig` proves commit-before-delivery,
  no-op suppression and that the view and presenter follow committed grid,
  cell-size and image-support changes, including a failed sidebar refresh.
- The owner test in `src/client/host/host_capabilities.zig` checks empty and stale commits
  (`client_tests.rejectStaleHostCommits`) before any effect runs.
- `src/client/panes/pane_graphics.zig` owns bounded fallback
  traversal; `src/model/state/tests/input_and_frames.zig` and
  `src/frontend/client/tests/graphics_and_clipboard.zig` cover fallback ownership,
  repeated values and graphics recovery.
- `src/frontend/client/host/host_capabilities.zig` owns terminal reply translation
  and probe expiry; `src/frontend/client/host/host_negotiation.zig` owns the
  color-probe window and fallback values.
- `src/client/host/host_capabilities.zig` owns commit delivery shared with resize;
  `src/frontend/client/presentation/view_chrome.zig` and
  `src/frontend/client/host/host_effects.zig` carry it to the TUI view and host.
- `src/frontend/client/tests/` proves fallback reconciliation,
  presenter-owned scheduling, timeout idempotence and retained state after a
  real resource failure.
