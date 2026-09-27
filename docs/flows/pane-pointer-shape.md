# Pane pointer shape

A child changes its mouse pointer through OSC 22. For example,
`ESC ] 22 ; pointer ST` requests a hand and `ESC ] 22 ; text ST` requests
text selection. Telar terminates this protocol at the runtime VT. The window
sets its own native cursor from the replicated shape; no child sequence
reaches the host.

## Ownership and delivery

```text
child OSC 22 -> pane_output -> Pane.ingest -> VT mouse_shape
             -> Pane.pointer_shape -> Attachment.prepareNextCells
             -> pane_frame.pointer_shape -> pane_frame.receive
             -> Pane.applyFrame -> Pane.pointer_shape (model)

native pointer -> GuiAdapter.dispatchPointer -> PointerHover.observe
               -> PointerHover.refresh -> hover_target.resolve
               -> PointerHover.shape

every GuiAdapter.update -> refreshPointer -> PointerHover.refresh
native pump -> pointer_shape callback (window_callbacks.pointerShape)
            -> macOS: telar_pointer_cursor -> NSCursor
            -> Linux: telar_cursor_apply -> wp_cursor_shape_v1 or cursor theme
```

The runtime owns the canonical shape for each pane. `Pane.pointerShape` maps
VT enum names to the shared `core.PointerShape`; it does not depend on
the VT enum's numeric ABI. The mapping is exhaustive, so adding a VT shape
requires an explicit protocol decision. The VT also owns alias handling,
malformed commands, reset behavior and parsing across PTY read boundaries.

The wire enum contains all 34 shapes in the pinned VT. Its explicit values
occupy one byte after the keyboard modes in each frame, making the body header
55 bytes. The decoder rejects every unknown value. Schema generation 42 uses
the updated golden-corpus fingerprint and rejects older clients and runtimes.
There is no historical decoder or raw-string escape hatch.

Each attachment includes the shape in its acknowledged baseline. A shape change
can produce a frame with zero cell spans. An outstanding frame keeps the next
update pending under the existing acknowledgement rules; intervening shapes
fold into the latest state. Another client's acknowledgement is independent.
Forced snapshots and new attachments recover the current shape from the same
runtime pane. No separate pointer message, timer or replay queue is introduced.

## Client policy

The window keeps the last native pointer position in `PointerHover` and
resolves it against the delivered chrome hit map and the current pane layout
(`hover_target.resolve`). Keyboard focus between panes does not select the
pointer shape.

- An unfocused window selects the default pointer.
- An open change review selects the default; a tab drag selects `grabbing`.
- A native modal and the notification stack give their controls `pointer`
  (text fields `text`) and everything else the default.
- An active name prompt or modal gives palette rows `pointer`, the modal's
  inside `text`, and everything else the default.
- An active sidebar resize, or a pointer over the resize band, selects
  `col-resize`. Clickable chrome selects `pointer`.
- Pane content supplies the child's shape; the child's `default` shows as
  `text`. A link under the pointer selects `pointer`, except in copy mode, over
  a detached pane or during a chrome gesture. A path found in prose is a link
  only while the platform modifier is held.

`GuiAdapter.update` refreshes the hover after every turn, so a layout, frame
or modal change under a stationary pointer updates the shape without pointer
motion. A refresh reuses the cached result while the cell, modifiers, model
version, pointer geometry, chrome revision and gestures are unchanged.

The native side asks for the shape through the `pointer_shape` callback after
input and after each client pump. On macOS `TelarPointerInputView` sets the
matching `NSCursor` while the pointer is inside the key window. On Linux
`telar_cursor_apply` sets it through the Wayland cursor-shape protocol when the
compositor offers it and through the cursor theme otherwise; both skip an
unchanged shape. Leaving the window restores the arrow.

## Bounds and lifecycle

This is interactive-path work with no steady-state allocations. Runtime and
client panes retain one enum; attachments retain one baseline enum. The window
retains one pointer event, one cached stamp and one shape. Lookup uses the
delivered hit map and the pane index.

Child death and detach use the existing pane lifecycle. Removing a pane removes
its pointer authority; another pane cannot inherit it through a stale ID.
Client death loses only physical pointer state. Reconnection reconstructs the
canonical shape in its first snapshot.

## Validation

- `src/backend/pane/pane_namespace.zig`: every canonical shape, every OSC byte split, the VT default,
  an alias, an invalid name and explicit default reset, with further allocation
  and resizing disabled after VT creation.
- `src/core/schema_contract_test.zig`: updated golden bytes and fingerprint, all 256
  possible pointer bytes, accepted enum values and rejection of unknown values.
- `src/backend/runtime/attachment/attachment_namespace.zig`: pointer-only frames, unchanged-state no-op,
  independent clients, slow acknowledgement, latest-wins updates, recovery
  snapshots and fresh attachments.
- `src/transport_integration_test.zig`: a real PTY child emits OSC 22, both clients
  receive its canonical shape alongside output, and one client survives the
  other's departure.
- `src/gui/tests/links.zig`: pane pointer shapes refresh under a stationary
  pointer, and a modal blocks links.
- `src/client_tests/presentation.zig`: decoded snapshots and zero-span pointer
  patches reach the presented pane without pointer movement, and survive a
  copy-mode round trip.
- `src/gui/linux/cursor_test.c`: the Wayland cursor-shape protocol, the cursor
  theme fallback and pointer leave.

Run `zig build test` for these contracts. Upgrading a running installation
requires matching runtime and client binaries. Restarting the runtime ends its
live PTYs, so schedule that restart rather than silently applying it.
