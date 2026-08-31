# Pane viewport

The client owns the visible scroll position of each pane. The runtime keeps a
per-attachment projection of that position so it can send the requested rows.
`ClientModel` is the authority inside the client. `multiplexer.Pane.scroll` is
the committed value, and `ClientModel.Version.viewport` records each local
change independently from pane structure and copy-mode state.

The transition runs on the interactive path. The model performs fixed
arithmetic and allocates nothing. Its runtime effect produces at most one
bounded outbox message. Repeated, missing, detached and inactive targets are
no-ops.

## Normal input

```text
mouse wheel or pane input
        |
InputHandler
        |
pane_viewports adapter or PaneInputHandler
        |
SetPaneViewportHandler
        |
ClientModel.setPaneViewport
        |
PaneViewportChange
        |
graphics visibility, then set_pane_viewport
```

`PaneViewportCommand` supports an absolute row, a relative movement and the
bottom of retained history. `InputHandler` uses the standalone adapter for
relative mouse-wheel movement. `PaneInputHandler` composes the same use case
with a `.bottom` intent before keyboard and paste delivery. Neither caller
clamps offsets, changes scroll state, hides graphics, sends viewport protocol
messages or requests a draw.

`ClientModel.setPaneViewport` resolves the intent against the attached pane in
the active tab. It clamps the offset to `scroll.maxOffset`, commits it and
advances only the viewport revision. An unchanged offset produces no change
and no effects. While copy mode is active, its transaction has exclusive
control of the viewport, so the standalone transition is rejected.

`SetPaneViewportHandler` calls the shared effect port after commit. The adapter
first updates client-owned graphics visibility and then sends
`set_pane_viewport` to the runtime. An effect failure does not roll back the
client viewport. The client process may reconnect, and the next runtime frame
rebuilds the operational projection.

Keyboard and paste input use `.bottom` before sending bytes to the child. Mouse
reports preserve scrollback because changing the viewport would alter the
interaction they describe. When the viewport changes, wire order is
`set_pane_viewport` followed by `pane_input`. The user's keyboard or paste
cannot overtake the request to return to live output.

## Copy mode

Copy-mode cursor movement and exit restore are part of the copy transaction,
not a second viewport use case. `ClientModel.commitCopyMode` commits both
states and returns the same `PaneViewportChange` value. `CopyModeHandler` then
uses the effect port from `pane_viewports`. This keeps copy delivery ordering
inside copy mode while leaving graphics and IPC knowledge in one adapter.

## Presentation

The event loop publishes `ClientModel.Version` after the input event.
`Presenter` compares the viewport revision with the version it last painted.
When it changes, the presenter invalidates each bounded tab composition cache
and renders only the active tab. Invalidating every cache is deliberate. A
single host read may fold movements from different panes, or restore a pane
and select another tab before the next 60 Hz frame. An inactive tab must not
retain cells composed for an older offset.

Neither the model transition nor the application handler touches
`composition_invalidated` or `InputHandler.redraw`. Runtime `pane_frame`
messages remain a separate reconciliation path. Applying a frame replaces the
pane's scroll projection, marks rendering damage and requests presentation.

## Runtime projection

```text
set_pane_viewport
        |
runtime.entrypoints.attachment.setPaneViewport
        |
Attachment.setViewport
        |
cell.Sync viewport pin
        |
pane_frame
        |
client handlePaneFrame
```

The attachment clamps the requested row against terminal history and pins the
chosen viewport. Reaching the bottom clears the pin and resumes the active
screen. A later frame carries the runtime's accepted `scroll` value. Client
death drops the attachment projection without changing the PTY or terminal.

## Proof

- `src/frontend/client/model.zig` proves clamping, relative movement,
  independent revisions, no-ops and copy-mode exclusivity.
- `src/frontend/client/application/set_pane_viewport.zig` proves commit-before-
  effect ordering and the failure policy.
- `src/frontend/client/client_test.zig` proves graphics visibility, folded
  revisions, presenter-owned cache invalidation and wire ordering before pane
  input.
- `src/backend/runtime/attachment/cell.zig` proves attachment-local viewport
  pinning and return to the live screen.
