# Pane resize

Pane layout belongs to one disposable client. The client may offer new pane
sizes to the runtime, but the runtime applies them only when that client holds
the workspace geometry lease.

Resize runs on the interactive path. Direction lookup walks the fixed layout
tree, and delivery uses the fixed client outbox. The flow allocates no queue
and waits for no runtime response.

## Client transition

```text
native, Lua or plugin resize action
        |
client_actions.apply
        |
ResizePane { direction, area }
        |
ResizePaneHandler
        |
ClientModel.resizePane
        |
pane_geometry.applyGeometry
        |                         |
pane_resize messages             Client.observeModel
        |                         |
runtime socket                   Presenter
```

The shared action dispatcher translates the direction and supplies the current
workbench rectangle. It does not inspect layout nodes, invalidate graphics or
request a frame.

`ClientModel.resizePane` moves the nearest split edge on the requested axis by
the layout's bounded step. It rejects an absent active tab, a missing matching
axis, a ratio at its limit, or a rectangle that would leave a pane without a
usable content cell. A commit advances only `ClientModel.Version.panes` and
returns the exact tab, focused pane, pane revision and request-time area.

Fullscreen does not destroy the tiled tree. A resize made while fullscreen
changes that hidden tree and becomes visible after fullscreen ends. This is
the existing client behavior, now owned by the model transition.

## Geometry effects and presentation

The adapter verifies the exact active tab, focused pane and committed pane
revision before it touches resources. It invalidates host graphics placements,
then `Client.resizeAttached` enqueues one `pane_resize` for each attached pane
that has visible geometry. A tiled layout normally sends every attached pane;
a fullscreen layout sends only the focused pane.

The outbox keeps a fixed bound and replaces an obsolete unsent resize for the
same pane. The runtime dispatches each message through
`pane_resize.Controller` and `PaneResizeHandler`. The controller counts stale
attachments and geometry-lease rejection. The handler applies or defers an
authorized PTY resize and then synchronizes observation, media and the client
cell projection. The protocol has no success reply.

Neither the use case nor the adapter invalidates `View` or requests a draw.
After the event, `Client.observeModel` lets `Presenter` observe the pane
revision and schedule one paced frame.

## Failure and recovery

The client commits layout before enqueueing geometry effects. If local
delivery fails, the error reaches the client loop with the new layout
preserved. Client shutdown leaves runtime panes and PTYs valid; reconnect
builds a fresh disposable layout and graphics state.

If the runtime rejects geometry authority or no longer has the attachment, it
keeps the PTY geometry unchanged and records the rejection. There is no client
rollback because the `pane_resize` protocol has no acknowledgement.

## Proof

- `src/frontend/workspace/layout.zig` proves direction lookup, bounded ratios
  and minimum usable pane geometry.
- `src/frontend/client/model.zig` proves semantic commit, no-op behavior,
  fullscreen preservation and pane-version ownership.
- `src/frontend/client/application/resize_pane.zig` proves
  commit-before-effects ordering and the post-commit failure contract.
- `src/frontend/client/client_test.zig` proves exact resize messages,
  presenter observation and directionless no-ops through a substituted runtime
  socket.
- `src/backend/runtime/pane_resize_test.zig` proves lease checks and runtime
  synchronization order.
