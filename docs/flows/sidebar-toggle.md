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
  -> actions.executeAction
  -> sidebar_toggle.toggleSidebar / resizeSidebar
  -> ClientModel commits visibility or width
  -> private sidebar_toggle.deliverSidebarLayout
       verify commit; queue placement invalidation; resize attached panes

after the event
  -> adapter drains model.to_host (placement invalidation)
  -> presentation_lifecycle.observe -> view_chrome.refresh
  -> Presenter compares model versions and schedules the paced frame
```

`ClientModel` is the source of truth for requested visibility and preferred
width. A toggle, exact pointer width or two-column keybinding step advances
only `model.chrome_revision`, reported as `Version.chrome`, and returns the
complete committed `SidebarLayout`. `sidebar.toggle`,
`setSidebarWidth` and `stepSidebarWidth` commit it. Explicit configuration
updates use `setSidebarVisible`; applying an identical layout is a no-op.

The shared action dispatcher calls the concrete sidebar operation. Lua
callback context also reads the committed model value, never the disposable
view projection.

## Effects and presentation

After the commit, `sidebar_toggle.deliverSidebarLayout` verifies visibility, width and
chrome revision. It sets `model.to_host.invalidate_placements` and publishes
the resulting size for every attached pane in the active tab through
`pane_resize.resizeAttachedPanes`, in that order. With no active tab it
stops after the invalidation. Configuration reload calls the same
`sidebar_toggle.deliverSidebarLayout` after its model transaction. Pane
geometry comes from `data.workbench.region(model)`, which derives the
workbench from the committed sidebar values, so geometry effects use the same
workbench that the next frame will show.

Neither the procedure nor the adapter requests a frame. After the input event,
the TUI's `events.zig` drains `model.to_host` through `host_effects.deliver`,
then calls `presentation_lifecycle.observe`. `view_chrome.refresh` copies the
sidebar values into the view when the chrome revision changed, and `Presenter`
detects the revision, invalidates the view and folds composition into the
paced frame loop.

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

- `src/model/state/ClientModel.zig` owns visibility, width and chrome revisions.
- `src/client/workspace/sidebar_toggle.zig` validates each commit and delivers graphics
  invalidation and pane geometry in order.
- `src/client/execution/client_tests.zig` rejects stale visibility, width and
  revision before touching any host effect.
- `src/frontend/client/tests/pane_lifecycle.zig` checks expanded, contracted and
  resized pane geometry and presenter-owned frame scheduling.
