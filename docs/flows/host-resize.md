# Host resize

Host geometry belongs to one disposable client. The runtime owns PTYs, but it
accepts the active client's pane sizes through bounded `pane_resize` messages.
A resize therefore commits client state before it changes presentation buffers
or offers new geometry to the runtime.

## End-to-end path

```text
SIGWINCH or Windows size poll
              |
     platform.ResizeWatcher
              |
      host_resizes.handle
              |
      one TTY measurement
              |
      host_resize.applyHostUpdate
              |
     host_capabilities.reconcile
              |
     host_resize.deliverHostCommit
              |
   pane_resize for each attached active pane
              |
   open_pane for each detached active pane that gained content
              |
 pixel queries and ResizeWatcher rearm
              |
 view_chrome.refresh: presenter, view and sidebar
              |
 host_effects.deliver: placement invalidation
              |
      presentation_lifecycle.observe
              |
           Presenter
```

The adapter reads `Tty.size()` once. Zero columns or rows become the platform
fallback of 80 by 24. Nonzero window pixels refresh the model-owned
`HostCapabilities`, which resolves the cell dimensions.

## Model transaction

`ClientModel` owns the resolved `core.TerminalSize` and the raw host
capabilities used to derive it. `reconcileHost` calls `TerminalSize.validate`
before either value changes, so an empty grid or one beyond the shared
frame-cell bound reaches no allocator or effect.

An exact repeated measurement is a no-op. Changed raw pixels advance
`Version.host_capabilities`; changed resolved geometry advances `Version.host`,
and stores the complete geometry in `model.host.host_size`. Tabs keep no copy:
`tab_layout.contentSize` reads the cell size from `model.host` for every
current tab and for tabs created or discovered later. A terminal pixel response uses the same
host transaction, so capability negotiation cannot leave a second geometry
value outside the model.

## Effects and failure

`host_resize.applyHostUpdate` commits before delivering its `HostCommit`.
The private `host_resize.deliverHostCommit` rejects empty or stale commits before effects.
Every accepted geometry sets `model.to_host.invalidate_placements` before pane
geometry is queued in `model.to_runtime`. Shared policy lives in
`src/client/host/host_resize.zig`. After the event the TUI follows the commit:
`view_chrome.refresh` resizes the presenter's front and back buffers and then
the client view on a grid change, and configures pixel-aware sidebar resources
for the committed cell size; `host_effects.deliver` invalidates physical
graphics placements. The GUI calls `host_resize.applyHostUpdate` from
`GuiAdapter` and drains the same queue in `GuiAdapter.deliverHostEffects`.

The model commit remains active if buffer allocation, sidebar configuration or
the bounded `model.to_runtime` outbox fails. The error terminates that client session;
runtime panes continue, and reconnect rebuilds disposable geometry. No
post-commit failure restores an older host size.

The transition and tab propagation use fixed-size state. Screen and view
buffers allocate only after validation and remain bounded by the shared
maximum cell count. `pane_resize` entries use the existing bounded,
latest-value outbox policy.

## Platform lifecycle and presentation

`client_startup.start` registers the initial observation through
`host_resizes.schedule` after the runtime handshake.
After successful synchronization, `host_resizes.handle` asks
`host_capabilities.refresh` to query the host. That adapter refreshes window and
cell pixels after a font or display-scale change, and issues OSC 10/11 when no
color probe is pending. The resize adapter then rearms the same `ResizeWatcher`. Neither the
resize adapter nor `view_chrome.refresh` requests a draw.

At the end of the inbox turn, `events.update` calls
`presentation_lifecycle.observe`, which publishes
`Version.host` and `Version.host_capabilities`. The presenter compares them
with the versions last painted and folds a change into its paced frame. A fully
repeated measurement still sends the two pixel queries and rearms the watcher,
but schedules no frame.

## Validation

- `src/model/workspace/tab_flow_tests.zig` proves that pane content sizes
  carry the host cell geometry.
- `src/model/state/tests/configuration_and_host.zig` proves validation, atomic capability and
  geometry commits, no-op behavior and isolated host revisions.
- `src/frontend/client/tests/host_resources.zig` proves that the view and
  presenter follow committed grid and cell changes, no-op policy and a failed
  sidebar refresh that keeps the commit.
- The owner test in `src/client/host/host_resize.zig` proves that empty and stale
  commits are rejected before any effect runs.
- `src/frontend/client/tests/host_interaction.zig` proves real resource changes,
  pane-size delivery and retained commits after outbox saturation.
- `src/frontend/client/host/host_resizes.zig` owns platform measurement, pixel
  refresh requests and watcher rearming.
- `src/client/host/host_resize.zig` owns commit delivery
  shared by resize and capability observations.
- `src/client/host/host_resize.zig` owns translation and bounded delivery
  of visible attached pane sizes.
- `src/client/host/host_resize.zig` proves
  that a resize attaches only detached panes with content, once each, after a
  crowded layout left them detached.
- `src/frontend/client/tests/` proves exact pane geometry,
  backpressure policy, capability-response consistency and presenter-owned
  frame scheduling.
