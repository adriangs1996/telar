# Host capabilities

Each client records the features of its own host. The result is disposable
client state. Graphics and mouse support never become runtime truth, because
two clients may run on different hosts. Known default colors are sent as
per-client values; the geometry owner supplies each pane's defaults. See
[terminal colors](terminal-colors.md).

Probing an exterior terminal (Kitty image queries, pixel reports, mode 1016
and OSC 10/11 color replies, with a 250 ms deadline) left with the terminal
client. The window and the headless client know their capabilities without
asking, so neither probes and neither arms a deadline.

## End-to-end path

```text
GuiAdapter.start / GuiAdapter.resize          HeadlessClient.start / resize line
        |                                               |
theme colors, images unsupported,             images and pixel mouse unsupported,
pixel mouse supported, cell metrics           8 x 16 pixels per cell
        |                                               |
        +-------------------+---------------------------+
                            |
             host_resize.applyHostUpdate
                            |
             host_capabilities.reconcile (model)
                            |
             host_resize.deliverHostCommit
                            |
             Client.presentation.observe after the turn
```

`GuiAdapter.start` and `GuiAdapter.resize` build the next `HostCapabilities`
from the current value: the renderer theme's foreground, background and
palette as terminal colors, `images = .unsupported`, `pointer_pixels =
.supported`, and window and cell pixels from the measured grid. A window
holding several machines shares that value with every other live client
through `window_machines.shareHost`. `HeadlessClient.start` reports images and
pixel mouse coordinates as unsupported and derives window pixels from a fixed
8 x 16 pixel cell.

`host_capabilities.observeHostCapability` and `reconcileHostCapabilities` still
exist in the shared client and feed the same model transaction from a semantic
`HostCapabilityObservation`. Only the client integration tests call them
today.

## Model transaction

`ClientModel` owns `HostCapabilities` in `model.host`. It stores independent
support states for graphics and pixel mouse coordinates, the terminal colors,
the light or dark appearance, and the latest raw window and cell pixel
measurements. Each support state starts as `unknown`.

`host_capabilities.reconcile` validates the resolved geometry first, then
commits capabilities and geometry as one `HostCommit`. An invalid or oversized
grid or a geometry inconsistent with its raw measurements changes neither
value. Capability changes advance `Version.host_capabilities`; geometry
changes independently advance `Version.host`
(`model.host.host_capabilities_revision` and `model.host.host_revision`).
Exact repeats advance neither version and run no effects.

## Effects and consumers

`host_resize.deliverHostCommit` validates that the commit is still current and
owns every branch shared with host resizing:

- changed terminal colors are queued to the runtime as
  `configure_terminal_colors` once startup is opening;
- a changed appearance writes `model.theme` from the configured light or dark
  theme unless `--theme` locked it;
- an image-support transition calls `pane_graphics.syncFallbacks`, which reads
  the committed capability and reconciles each bounded pane cell fallback,
  then sets `model.to_host.invalidate_placements`;
- a geometry transition runs the same pane-size branch as a host resize.

Pixel mouse support is effect-free; `pointer_routing` reads it when it
converts the next mouse event. Configuration validation and
pane-graphics policy read immutable capability values from `ClientModel`.

A failed effect does not restore older capabilities. The error leaves the
event with the committed disposable state; runtime panes continue and a
reconnect builds a fresh model.

## Presentation

Capability updates never request a draw. After the inbox turn,
`GuiAdapter.update` passes the model version to `Client.presentation.observe`,
and a changed version asks for one paced frame. A repeated update schedules no
frame.

## Validation

- `src/model/state/tests/configuration_and_host.zig` proves independent
  observations, pixel precedence, atomic geometry and validation before
  mutation.
- `src/client_tests/host_resources.zig` proves commit-before-delivery, no-op
  suppression and that presentation follows committed grid, cell-size and
  image-support changes.
- `src/client_tests/host_interaction.zig` proves oversized measurements change
  nothing, pixel responses keep model geometry authoritative, and a graphics
  capability commits before fallback projection and presentation.
- The owner test in `src/client/host/host_resize.zig` checks empty and stale
  commits (`client_tests.rejectStaleHostCommits`) before any effect runs.
- `src/client/panes/pane_graphics.zig` owns bounded fallback traversal;
  `src/model/state/tests/input_and_frames.zig` and
  `src/client_tests/graphics_and_clipboard.zig` cover fallback ownership,
  repeated values and graphics recovery.
