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
      AttachedClient.applyHostUpdate
              |
     ClientModel.reconcileHost
              |
     AttachedClient.deliverHostCommit
              |
 screen, view, sidebar and graphics effects
              |
   pane_resize for each attached active pane
              |
   open_pane for each detached active pane that gained content
              |
 pixel queries and ResizeWatcher rearm
              |
      presentation_lifecycle.observe
              |
           Presenter
```

The adapter reads `Tty.size()` once. Zero columns or rows become the platform
fallback of 80 by 24. Nonzero window pixels refresh the model-owned
`HostCapabilities`, which resolves the cell dimensions.

## Model transaction

`ClientModel` owns the resolved `schema.TerminalSize` and the raw host
capabilities used to derive it. `reconcileHost` calls `TerminalSize.validate`
before either value changes, so an empty grid or one beyond the shared
frame-cell bound reaches no allocator or effect.

An exact repeated measurement is a no-op. Changed raw pixels advance
`Version.host_capabilities`; changed resolved geometry advances `Version.host`,
stores the complete geometry and updates the cell size held by the tab
collection. The tab collection applies it to every current tab and retains it
for tabs created or discovered later. A terminal pixel response uses the same
host transaction, so capability negotiation cannot leave a second geometry
value outside the model.

## Effects and failure

`AttachedClient.applyHostUpdate` commits before delivering its `HostCommit`.
The private `AttachedClient.deliverHostCommit` rejects empty or stale commits before effects and
calls the host ports directly in order. A grid change resizes the presenter's front and back
buffers and then the client view. A changed cell size configures pixel-aware
sidebar resources. Every accepted geometry invalidates physical graphics
placements before pane geometry is offered. Shared policy lives in
`src/client/AttachedClient.zig`; GUI and TUI provide the host
ports. There is no intermediate handler or host-effect callback table.

The model commit remains active if buffer allocation, sidebar configuration or
the bounded client outbox fails. The error terminates that client session;
runtime panes continue, and reconnect rebuilds disposable geometry. No
post-commit failure restores an older host size.

The transition and tab propagation use fixed-size state. Screen and view
buffers allocate only after validation and remain bounded by the shared
maximum cell count. `pane_resize` entries use the existing bounded,
latest-value outbox policy.

## Platform lifecycle and presentation

`client_startup` registers the initial observation through
`host_resizes.schedule` after the runtime handshake.
After successful synchronization, `host_resizes.handle` asks
`host_capabilities.refresh` to query the host. That adapter refreshes window and
cell pixels after a font or display-scale change, and issues OSC 10/11 when no
color probe is pending. The resize adapter then rearms the same `ResizeWatcher`. Neither the
resize adapter nor the common host-resource operation requests a draw.

At the client-loop boundary, `presentation_lifecycle.observe` publishes
`Version.host` and `Version.host_capabilities`. The presenter compares them
with the versions last painted and folds a change into its paced frame. A fully
repeated measurement still sends the two pixel queries and rearms the watcher,
but schedules no frame.

## Validation

- `src/client/workspace/tabs.zig` proves that current and future tabs share
  one cell geometry.
- `src/client/model/Model.zig` proves validation, atomic capability and
  geometry commits, no-op behavior and isolated host revisions.
- `src/frontend/client/tests/host_resources.zig` proves commit-before-delivery,
  exact branch ordering, no-op policy and failures at each fallible host port.
- The owner test in `src/client/AttachedClient.zig` proves that empty and stale
  commits are rejected before any host port can be accessed.
- `src/frontend/client/tests/host_interaction.zig` proves real resource changes,
  pane-size delivery and retained commits after outbox saturation.
- `src/frontend/client/controllers/host/host_resizes.zig` owns platform measurement, pixel
  refresh requests and watcher rearming.
- `src/client/AttachedClient.zig` owns ordered resource delivery
  shared by resize and capability observations.
- `src/client/AttachedClient.zig` owns translation and bounded delivery
  of visible attached pane sizes.
- `src/client/operations/tabs/tab_snapshots.zig` proves
  that a resize attaches only detached panes with content, once each, after a
  crowded layout left them detached.
- `src/frontend/client/tests/` proves exact pane geometry,
  backpressure policy, capability-response consistency and presenter-owned
  frame scheduling.
