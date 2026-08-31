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
   Client.handleResizeEvent
              |
      host_resizes.handle
              |
      one TTY measurement
              |
      ResizeHostHandler
              |
     ClientModel.reconcileHost
              |
 screen, view, sidebar and graphics synchronization
              |
   pane_resize for each attached active pane
              |
 pixel queries and ResizeWatcher rearm
              |
      Client.observeModel
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

`ResizeHostHandler` commits before calling its effect port. A grid change
resizes the presenter's front and back buffers and the client view. A changed
cell size configures pixel-aware sidebar resources. Every accepted geometry
invalidates physical graphics placements and offers each attached pane in the
active tab its size within the new workbench.

The model commit remains active if buffer allocation, sidebar configuration or
the bounded client outbox fails. The error terminates that client session;
runtime panes continue, and reconnect rebuilds disposable geometry. No
post-commit failure restores an older host size.

The transition and tab propagation use fixed-size state. Screen and view
buffers allocate only after validation and remain bounded by the shared
maximum cell count. `pane_resize` entries use the existing bounded,
latest-value outbox policy.

## Platform lifecycle and presentation

After successful synchronization, the adapter writes `CSI 14 t` and
`CSI 16 t`. These queries refresh window and cell pixels after a font or
display-scale change. It then rearms the same `ResizeWatcher`. Neither the
handler nor its adapter requests a draw.

At the client-loop boundary, `Client.observeModel` publishes `Version.host` and
`Version.host_capabilities`. The presenter compares them with the versions last
painted and folds a change into its paced frame. A fully repeated measurement
still sends the two pixel queries and rearms the watcher, but schedules no
frame.

## Proof

- `src/frontend/workspace/tabs.zig` proves that current and future tabs share
  one cell geometry.
- `src/frontend/client/model.zig` proves validation, atomic capability and
  geometry commits, no-op behavior and isolated host revisions.
- `src/frontend/client/application/host_resize.zig` proves commit-before-
  effect ordering and retained commits after effect failure.
- `src/frontend/client/host_resizes.zig` owns platform measurement, resource
  synchronization, pixel queries and watcher rearming.
- `src/frontend/client/client_test.zig` proves exact pane geometry,
  backpressure policy, capability-response consistency and presenter-owned
  frame scheduling.
