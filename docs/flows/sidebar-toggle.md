# Sidebar toggle

Sidebar visibility is disposable client state. It changes client chrome and
the workbench rectangle, but it does not change runtime pane membership or
the pane layout tree.

The transition runs on the interactive path. It uses fixed-size state values
and the bounded client outbox, allocates no queue and waits for no runtime
reply.

## Client transition

```text
native, Lua or plugin sidebar action
        |
client_actions.apply
        |
ToggleSidebarHandler
        |
ClientModel.toggleSidebar
        |
sidebar_toggles.applyVisibility
        |
sidebar_projection.apply
        |
DeliverSidebarVisibilityHandler
        |                         |
View projection and pane_resize  presentation_lifecycle.observe
        |                         |
runtime socket                   Presenter
```

`ClientModel` is the source of truth for the requested visibility. A toggle
advances only `ClientModel.Version.chrome` and returns the committed value and
revision. Explicit configuration updates use `setSidebarVisible`; applying an
identical value is a no-op.

The shared action dispatcher only translates the action and delegates. Lua
callback context also reads the committed model value, never the disposable
view projection.

## Effects and presentation

After the commit, `DeliverSidebarVisibilityHandler` verifies the visibility
and chrome revision. It projects the value into `View`, invalidates graphics
placements and publishes the resulting size for every attached pane in the
active tab, in that order. With no active workspace it completes after the
first two effects. Configuration reload reaches the same handler through the
`sidebar_projection` adapter after its model transaction. The adapter supplies
only view, graphics and geometry ports. This immediate projection gives
geometry effects the same workbench that the next frame will show.

Neither the use case nor the adapter requests a frame. After the input event,
`client_events` calls `presentation_lifecycle.observe`. `Presenter` detects the
chrome revision, idempotently synchronizes the view projection, invalidates it and
folds composition into the paced frame loop.

Hiding the sidebar expands the workbench and both bars. Showing it gives the
sidebar the complete left column, so the workbench, top bar and bottom bar
share the remaining width. Narrow hosts may preserve the same effective
rectangles while still retaining the requested visibility for a later resize.

## Failure and recovery

The preference commits before graphics and geometry effects. If an effect
cannot complete, the error reaches the client loop with the committed model
value preserved. The client exits rather than presenting state whose runtime
geometry may be incomplete. Runtime panes and PTYs remain alive, and reconnect
reconstructs the disposable projection from client configuration and runtime
snapshots.

The `pane_resize` protocol has no success response. A runtime rejection leaves
the previous PTY size intact and increments runtime telemetry; it does not
roll back the client preference.

## Proof

- `src/frontend/client/model.zig` proves source-of-truth ownership, no-op
  assignment and chrome-revision isolation.
- `src/frontend/client/application/toggle_sidebar.zig` proves
  commit-before-effects ordering and post-commit failure behavior.
- `src/frontend/client/application/sidebar_visibility_delivery.zig` proves
  exact commit validation, complete effect order, empty-workspace behavior and
  partial geometry failures.
- `src/frontend/client/sidebar_projection.zig` wires the physical ports shared
  with configuration reload.
- `src/frontend/client/view.zig` proves the top-bar click returns intent
  without mutating the requested visibility.
- `src/frontend/client/client_test.zig` proves exact expanded and contracted
  `pane_resize` messages, rejection before partial effects, absence of direct
  presentation scheduling and presenter-only frame scheduling through a
  substituted runtime socket.
