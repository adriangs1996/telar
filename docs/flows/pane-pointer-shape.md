# Pane pointer shape

A child changes its mouse pointer through OSC 22. For example,
`ESC ] 22 ; pointer ST` requests a hand and `ESC ] 22 ; text ST` requests
text selection. Telar terminates this protocol at the runtime VT. It never
forwards the child's sequence directly to the host terminal.

## Ownership and delivery

```text
child OSC 22 -> pane_output -> Pane.ingest -> VT mouse_shape
             -> Pane.pointer_shape -> Attachment.prepareNextCells
             -> pane_frame.pointer_shape -> ClientModel.applyPaneFrame
             -> multiplexer.Pane.pointer_shape

host mouse -> pointer_routing -> View.handleMouse -> client pointer position

pane frame or view change -> paced presentation -> View.render
                         -> pointer policy -> Screen.flush -> host OSC 22
```

The runtime owns the canonical shape for each pane. `Pane.pointerShape` maps
VT enum names to the shared `schema.frame.PointerShape`; it does not depend on
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

The client retains the last routed pointer position and resolves it against
current hit regions and the compositor's pane-content geometry. Keyboard focus
does not select the pointer shape.

- Copy mode and active prompts select the default pointer.
- An active sidebar resize keeps `ew-resize` throughout its gesture.
- Clickable chrome, attachment shelves and modal controls retain their own
  shape. An attachment modal prevents underlying panes from supplying it.
- Only the content of an attached, visible pane can supply its child shape.
  Borders, missing panes and detached panes select the default.

Prompt and copy-mode ownership changes clear the cached pointer position. Mouse
motion consumed by those owners cannot leave a stale pane or chrome shape when
normal routing resumes; the next routed mouse event establishes the position.

The view resolves the shape after rebuilding hit regions. Layout changes under
a stationary pointer therefore cannot retain a shape from stale geometry. It
also resolves the shape on the render fast path: a pointer-only frame needs
neither a mouse movement nor cell or chrome damage to take effect.

The last projected content rectangle distinguishes pane-border crossings from
movement inside the same pane. A crossing advances the view interaction
revision. Movement within the same content rectangle and hit action does not
invalidate chrome. This metadata does not change focus, hit actions, gesture
ownership or child mouse encoding.

`presentation.pointer` emits a static CSS-name sequence for every enum value,
including the explicit `default` reset. Sequences are at most 20 bytes. Only
`Screen.flush` writes them, inside the normal synchronized presentation path,
and only when the selected shape changes. Failed output invalidates the cached
shape so recovery re-emits it. Leaving the client restores the host default.

## Bounds and lifecycle

This is interactive-path work with no steady-state allocations. Runtime and
client panes retain one enum; attachments retain one baseline enum. The view
retains one optional cell position and one content rectangle. Production lookup
uses the existing bounded hit map, pane index and compositor geometry index.
The view-only fallback builds a bounded layout snapshot on the stack.

Child death and detach use the existing pane lifecycle. Removing a pane removes
its pointer authority; another pane cannot inherit it through a stale ID.
Client death loses only physical pointer state. Reconnection reconstructs the
canonical shape in its first snapshot. Hosts without OSC 22 support may ignore
the selected shape without affecting input or cell output.

## Proof

- `pane/root.zig`: every canonical shape, every OSC byte split, the VT default,
  an alias, an invalid name and explicit default reset, with further allocation
  and resizing disabled after VT creation.
- `schema_contract_test.zig`: updated golden bytes and fingerprint, all 256
  possible pointer bytes, accepted enum values and rejection of unknown values.
- `runtime/attachment/root.zig`: pointer-only frames, unchanged-state no-op,
  independent clients, slow acknowledgement, latest-wins updates, recovery
  snapshots and fresh attachments.
- `transport_integration_test.zig`: a real PTY child emits OSC 22, both clients
  receive its canonical shape alongside output, and one client survives the
  other's departure.
- `client/presentation/view.zig`: unfocused panes, all wire shapes, stationary
  metadata updates without chrome scans, borders, prompts, copy mode, resize
  ownership, attachment modals, detach and removal under a stationary pointer.
  Existing focus-intent assertions remain unchanged.
- `client/tests/presentation.zig`: decoded snapshots and zero-span pointer
  patches reach host presentation without pointer movement; chrome takes over
  on hover, and leaving copy mode cannot restore stale hover.
- `presentation/pointer.zig` and `presentation/screen.zig`: bounded static CSS
  sequences, unchanged-shape suppression, output invalidation and re-emission.

Run `zig build test` for these contracts. Upgrading a running installation
requires matching runtime and client binaries. Restarting the runtime ends its
live PTYs, so schedule that restart rather than silently applying it.
