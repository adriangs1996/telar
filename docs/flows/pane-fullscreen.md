# Pane fullscreen

Fullscreen is disposable client layout state. It changes which pane the client
shows and which attached sizes it offers to the runtime. It does not change
runtime pane membership or destroy the tiled split tree.

The action runs on the interactive path. It uses fixed-size model values and
the bounded client outbox, allocates no queue and waits for no runtime reply.

## Client transition

```text
native, Lua or plugin fullscreen action
        |
client_actions.apply
        |
TogglePaneFullscreen { area }
        |
TogglePaneFullscreenHandler
        |
ClientModel.togglePaneFullscreen
        |
pane_geometry.applyGeometry
        |                         |
pane_resize messages             presentation_lifecycle.observe
        |                         |
runtime socket                   Presenter
```

The shared action dispatcher supplies the current workbench rectangle and
delegates. It does not inspect the layout, invalidate `View` or request a draw.

`ClientModel.togglePaneFullscreen` rejects an absent active tab or a tab with
fewer than two panes. A commit keeps the focused pane identity, toggles the
fullscreen flag and advances only `ClientModel.Version.panes`. The returned
change carries the exact tab, focus, pane revision, area and new fullscreen
state.

The layout retains every split ratio while fullscreen is active. Directional
focus and resize may still alter that hidden tiled tree. Exiting fullscreen
reveals the retained geometry.

## Geometry effects and presentation

Fullscreen and edge resizing share `pane_geometry.applyGeometry` because both
need the same resource synchronization after their separate model commits.
The adapter verifies active tab, focus, pane revision and fullscreen state. It
then invalidates host graphics placements and publishes current attached
geometry.

Entering fullscreen gives the entire workbench to the focused pane, so the
client sends one `pane_resize`. Exiting restores the tiled snapshot and sends
one resize for each attached pane. The runtime accepts those messages only
from the workspace geometry owner and processes them through
`pane_resize.Controller` and `PaneResizeHandler`.

The protocol has no success response. Independently, `client_events` calls
`presentation_lifecycle.observe`. `Presenter` observes the pane revision and
schedules the paced frame that changes the visible composition.

## Failure and recovery

The fullscreen flag commits before graphics and resize effects. A local effect
failure reaches the client loop with that flag preserved. Client shutdown does
not stop runtime panes or PTYs. Reconnect builds fresh disposable layout and
graphics state from runtime snapshots.

A runtime geometry rejection leaves PTY size unchanged and increments runtime
telemetry. The client does not roll back an unacknowledged resize.

## Proof

- `src/frontend/workspace/layout.zig` proves that fullscreen retains tiled
  ratios, follows focus and clears when pane count falls below two.
- `src/frontend/client/model.zig` proves entry, exit, single-pane no-op and
  pane-version ownership.
- `src/frontend/client/application/toggle_pane_fullscreen.zig` proves
  commit-before-effects ordering and post-commit failure behavior.
- `src/frontend/client/client_test.zig` proves the one-pane enter resize, the
  tiled exit resizes and presenter-only frame scheduling through a substituted
  runtime socket.
