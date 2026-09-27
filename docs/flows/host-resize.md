# Host resize

Host geometry belongs to one disposable client. The runtime owns PTYs, but it
accepts the active client's pane sizes through bounded `pane_resize` messages.
A resize therefore commits client state before it offers new geometry to the
runtime.

## End-to-end path

```text
native render callback with the current viewport
              |
      GuiAdapter.draw(viewport)
              |
      GuiAdapter.resizeViewport
              |
      GuiAdapter.measure -> TerminalRenderer.measure (one grid)
              |
      GuiAdapter.resize
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
   window_machines.shareHost: the same update for every other live client
              |
      Client.presentation.observe
```

The window measures its grid when a viewport arrives: `windowReady` for the
first one, then every `draw`. `TerminalRenderer.measure` subtracts chrome bands
and padding and counts whole cells; see
[native multiplexer](gui-multiplexer.md). `GuiAdapter.resize` publishes the
cell metrics, window pixels and theme colors as `HostCapabilities` beside the
resolved grid. The headless client applies the same update from a `resize`
stdin line with a fixed 8 x 16 pixel cell.

## Model transaction

`ClientModel` owns the resolved `core.TerminalSize` and the raw host
capabilities used to derive it. `host_capabilities.reconcile` calls
`TerminalSize.validate` before either value changes, so an empty grid or one
beyond the shared frame-cell bound reaches no allocator or effect.

An exact repeated measurement is a no-op. Changed raw pixels advance
`Version.host_capabilities`; changed resolved geometry advances `Version.host`,
and stores the complete geometry in `model.host.host_size`. Tabs keep no copy:
`tab_layout.contentSize` reads the cell size from `model.host` for every
current tab and for tabs created or discovered later.

## Effects and failure

`host_resize.applyHostUpdate` commits before delivering its `HostCommit`.
`host_resize.deliverHostCommit` rejects empty or stale commits before effects.
Every accepted geometry sets `model.to_host.invalidate_placements` before pane
geometry is queued in `model.to_runtime`. Shared policy lives in
`src/client/host/host_resize.zig`. The window drains the same queue in
`GuiAdapter.deliverHostEffects`; it redraws every image placement each frame,
so it only clears the invalidation flag.

The model commit remains active if the bounded `model.to_runtime` outbox fails.
The error terminates that client session; runtime panes continue, and
reconnect rebuilds disposable geometry. No post-commit failure restores an
older host size.

The transition and tab propagation use fixed-size state. `pane_resize` entries
use the existing bounded, latest-value outbox policy.

## Presentation

`GuiAdapter.resizeViewport` refuses to run while a presentation is in flight,
so geometry changes only between frames. Neither the resize nor the host
commit requests a draw. The window's next preparation captures the new
`Version.host` and `Version.host_capabilities` through
`Client.presentation.observe` and folds the change into that frame. A fully
repeated measurement schedules no extra frame.

## Validation

- `src/model/workspace/tab_flow_tests.zig` proves that pane content sizes
  carry the host cell geometry.
- `src/model/state/tests/configuration_and_host.zig` proves validation, atomic
  capability and geometry commits, no-op behavior and isolated host revisions.
- `src/client_tests/host_resources.zig` proves that presentation follows
  committed grid and cell changes and the no-op policy.
- The owner test in `src/client/host/host_resize.zig` proves that empty and
  stale commits are rejected before any effect runs.
- `src/client_tests/host_interaction.zig` proves pane-size delivery, retained
  commits after outbox saturation, attachment only of detached panes with
  content, once each, and rollback of rejected attachment correlation.
- `src/client/host/host_resize.zig` owns commit delivery shared by resize and
  capability observations.
