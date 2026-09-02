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
DeliverPaneGeometryHandler
        |
OfferPaneGeometryHandler
        |                         |
pane_resize messages             presentation_lifecycle.observe
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

`DeliverPaneGeometryHandler` verifies the exact active tab, focused pane,
fullscreen state and committed pane revision before it touches resources. It
invalidates host graphics placements and delegates selection to
`OfferPaneGeometryHandler`. That handler computes one bounded layout snapshot
and applies the current attachment reservation. The reservation shortens only
its owning pane, leaving neighboring pane rectangles unchanged. The handler
then emits one semantic `PaneResize` for each attached pane with visible
content. A tiled layout normally selects every attached pane; a fullscreen
layout selects only the focused pane. The concrete adapter only enqueues those
commands.

Flows that need the current projection use `OfferActivePaneGeometryHandler`.
It selects the active tab once and delegates to the same bounded offer handler;
an empty client returns zero without effects. `pane_geometry.offerActive`
supplies only the concrete resize port and is shared by attachment changes,
host resources, clipboard-image adoption and configuration reload.

The outbox keeps a fixed bound and replaces an obsolete unsent resize for the
same pane. The runtime dispatches each message through
`pane_resize.Controller` and `PaneResizeHandler`. The controller counts stale
attachments and geometry-lease rejection. The handler applies or defers an
authorized PTY resize and then synchronizes observation, media and the client
cell projection. The protocol has no success reply.

Neither the use case nor the adapter invalidates `View` or requests a draw.
After the event, `presentation_lifecycle.observe` lets `Presenter` observe the pane
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
  commit-before-delivery ordering and the post-commit failure contract.
- `src/frontend/client/application/pane_geometry_delivery.zig` proves exact
  commit validation, active-tab selection, empty-client behavior,
  attached-visible filtering, effect order and partial delivery failure.
- `src/frontend/client/pane_geometry.zig` implements placement invalidation and
  runtime `pane_resize` delivery ports.
- `src/frontend/client/client_test.zig` proves exact resize messages, detached
  pane filtering, presenter observation and directionless no-ops through a
  substituted runtime socket.
- `src/backend/runtime/pane_resize_test.zig` proves lease checks and runtime
  synchronization order.
