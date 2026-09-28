# Sidebar layout

Sidebar visibility and preferred width are semantic client-layout state. They
change client chrome and the workbench rectangle, but do not change runtime
pane membership or the split tree. The runtime retains their latest bounded
snapshot for reconnecting clients while the server is alive. The window reads
the visibility; its band width is its own pixel preference.

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
  -> GuiAdapter.deliverHostEffects drains model.to_host
  -> app.presentation.observe -> the window prepares a frame
  -> GuiAdapter.draw -> resizeViewport -> measure with the sidebar band
  -> host_resize.applyHostUpdate when the grid size changed

window width step or band drag
  -> GuiAdapter.executeAction(.resize_sidebar) / adoptSidebarWidth
  -> SidebarPreference.step / drag -> chrome.invalidate
  -> the next measurement resizes the grid
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
`GuiAdapter.update` drains `model.to_host` and passes its observation to
`app.presentation.observe`; the chrome revision makes the next frame due.

`workbench.region` derives the workbench from the sidebar values only when the
host sets `model.host.grid_chrome`, as the terminal client did and the client
test harness still does. The window leaves it false: its workbench is the
whole grid, and the sidebar is a pixel band outside it. At the next draw
`GuiAdapter.measure` asks the renderer for the grid with
`SidebarPreference.request(model.sidebar_visible)`; a changed grid size goes
through `host_resize.applyHostUpdate`, which resizes the attached panes. See
[GUI multiplexer](gui-multiplexer.md) for the band's bounds.

The window's keyboard width step and band drag change `SidebarPreference`, a
disposable pixel width seeded from `gui.sidebar.width`, and never
`model.sidebar_width`. Clamping to the window changes only visible geometry;
it never overwrites the preferred width.

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
- `src/client_tests/pane_lifecycle.zig` checks expanded, contracted and
  resized pane geometry on a grid-chrome host and frame scheduling through
  observation.
