# Sidebar layout

Sidebar visibility and preferred width are semantic client-layout state. They
change client chrome and the workbench rectangle, but do not change runtime
pane membership or the split tree. The runtime retains their latest bounded
snapshot for reconnecting terminals while the server is alive.

The transition runs on the interactive path. It uses fixed-size state values
and the bounded client outbox, allocates no queue and waits for no runtime
reply.

## Client transition

```text
native, Lua, plugin or pointer sidebar action
  -> AttachedClient.executeAction
  -> AttachedClient.toggleSidebar / resizeSidebar
  -> Model commits visibility or width
  -> private AttachedClient.deliverSidebarLayout
       verify commit; project chrome; invalidate graphics; resize attached panes

next presentation observation
  -> Presenter compares model versions and schedules the paced frame
```

`ClientModel` is the source of truth for requested visibility and preferred
width. A toggle, exact pointer width or two-column keybinding step advances
only `ClientModel.Version.chrome` and returns the complete committed layout.
Explicit configuration updates use `setSidebarVisible`; applying an identical
layout is a no-op.

The shared action dispatcher calls the concrete sidebar operation. Lua
callback context also reads the committed model value, never the disposable
view projection.

## Effects and presentation

After the commit, `AttachedClient.deliverSidebarLayout` verifies visibility, width and
chrome revision. It projects both values into `View`, invalidates graphics
placements and publishes the resulting size for every attached pane in the
active tab, in that order. With no active workspace it completes after the
first two effects. Configuration reload calls the same
`AttachedClient.deliverSidebarLayout` operation after its model transaction. That function
calls the chrome and graphics service ports and `AttachedClient.resizeAttachedPanes`
directly. This immediate projection gives
geometry effects the same workbench that the next frame will show.

Neither the use case nor the adapter requests a frame. After the input event,
`client_events` calls `presentation_lifecycle.observe`. `Presenter` detects the
chrome revision, idempotently synchronizes the view projection, invalidates it and
folds composition into the paced frame loop.

Hiding the sidebar expands the workbench and both bars. Showing or resizing it
gives the sidebar the complete left column, so the workbench, top bar and
bottom bar share the remaining width. Host clamping changes only visible
geometry; it never overwrites the preferred width.

## Failure and recovery

The preference commits before graphics and geometry effects. If an effect
cannot complete, the error reaches the client loop with the committed model
value preserved. The client exits rather than presenting state whose runtime
geometry may be incomplete. Runtime panes and PTYs remain alive, and reconnect
restores the retained client layout before attaching its first pane.

The `pane_resize` protocol has no success response. A runtime rejection leaves
the previous PTY size intact and increments runtime telemetry; it does not
roll back the client preference.

## Validation

- `src/model/state/Model.zig` owns visibility, width and chrome revisions.
- `src/client/AttachedClient.zig` validates each commit and delivers chrome,
  graphics invalidation and pane geometry in order.
- `src/client/attached_client_tests.zig` rejects stale visibility, width and
  revision before accessing a host port.
- `src/frontend/client/tests/pane_lifecycle.zig` checks expanded, contracted and
  resized pane geometry and presenter-owned frame scheduling.
