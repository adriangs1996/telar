# Mouse selection

Left-drag selects text within a pane. Double click selects a whitespace-delimited
word, including punctuation; triple click selects a physical row. Dragging after
a double or triple click extends by that same unit. Releasing the left button
copies through the existing `copy_selection` / `pane_clipboard` exchange and
OSC 52 host clipboard writer. A bare click does not copy.

A child with mouse tracking retains ordinary presses. Shift-left press forces
Telar selection, including over textual links, if the host terminal delivers
the modifier. Some terminals intercept Shift-drag for their own selection;
Telar cannot handle events the host does not send. Plain link clicks retain
the existing opening behavior.

## Entry and ownership

```text
InputHandler.mouse
    -> pointer_routing: normalize host pixels to cells
    -> CopyModePointerHandler: captured gesture first
    -> view_interactions: focus the clicked pane
    -> link_openings: ordinary links retain priority
    -> PaneMouseHandler: choose selection or child report
    -> copy_modes.beginPointer -> CopyModeHandler.beginPointer
    -> ClientModel.beginPointerSelection

captured drag / release
    -> CopyModePointerHandler
    -> copy_modes.pointer -> CopyModeHandler.execute
    -> ClientModel.planCopyMode
    -> copy_selection before commit, on release only
    -> ClientModel.commitCopyMode
    -> Version.copy -> Presenter -> Compositor

runtime copy_selection
    -> existing runtime selection extraction from the VT
    -> pane_clipboard -> host OSC 52 writer
```

The client owns the range, click tracker and physical gesture. Mouse selection
reuses `copy_state` and its immutable projection but does not enter keyboard
copy mode, move the child cursor or restore the entry viewport. Typing and
pasting clear highlighting through `PaneInputHandler` and still reach the child.
A new press or mouse wheel clears a completed selection before normal routing.

`selection_gesture` retains only the pane ID from the press. It survives clearing
highlighting, pane retirement and tab changes so subsequent drag and release
cannot reach another pane or client chrome. Coordinates clamp to the captured
pane's content, even over a border, sidebar or another pane. Other buttons do
not release capture. A new left press replaces an abandoned gesture.

Release relinquishes physical capture even if the outbox rejects the copy.
The failed transaction retains the previous range and copy revision. It does
not trap subsequent input. Unavailable geometry cancels rather than copying
coordinates from another pane. No borrowed pane pointer survives an event.

## Bounds and lifecycle

This is interactive client state. Begin, drag, release and projection allocate
nothing and add no queue. Character movement is constant-time; word expansion
scans at most one bounded pane row. Click counts saturate at three. Rendering
uses the existing paced compositor and copy damage ranges. Clipboard requests
contain coordinates; runtime extraction and host delivery retain their existing
64 KiB payload limit.

The range uses absolute retained-history rows. Frame reconciliation adjusts the
range and captured word boundaries when retained history is pruned. A changed
pane grid size cancels the range because reflow invalidates its coordinates.
Pane retirement and leaving the active tab discard highlighting. Client death
discards all selection state; reconnect does not restore it or interrupt PTYs.

The VT extracts text, so pane borders and sidebar cells never enter the copy.
Wide glyphs include both cells in highlighting and copying. Word expansion does
not treat a wide glyph's continuation cell as whitespace.

This implementation clips at the viewport edge. It does not auto-scroll during
a drag, offer rectangular mouse selection, or expand a triple click across
soft-wrapped rows. Clipboard delivery still depends on host OSC 52 permission.

## Proof

- `src/core/select.zig`: word boundaries, whitespace, wide glyph continuations
  and saturated click counts.
- `src/client/input/copy_mode.zig`: reverse word drags, clipping, wide glyph
  endpoints, bare clicks and retained-history reconciliation.
- `src/client/application/input/copy_mode.zig`: double/triple click
  copying, single delivery, unchanged viewport and failed-copy capture release.
- `src/client/application/input/copy_mode_pointer.zig`: matching-button
  ownership and cancellation when geometry disappears.
- `src/frontend/client/tests/mouse_selection.zig`: real input, focus-before-press,
  cross-border capture, mid-gesture child mode changes, Shift over links,
  retired-pane capture, outbox coordinates, paced highlighting and typing.
- Existing backend selection tests and host clipboard tests cover VT extraction
  and OSC 52 delivery without adding a second copy implementation.
