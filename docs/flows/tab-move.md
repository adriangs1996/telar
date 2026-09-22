# Tab move

The runtime owns tab order. Keyboard input sends a direction; pointer release
sends captured source/anchor identities and before/after placement. Neither
predicts the canonical absolute position.

```text
AttachedClient.executeAction or GUI/TUI tab drag release
  -> operations/tabs/tab_moves.request
     -> pending-operation gate, resolve source and optional anchor
     -> AttachedClient.sendRuntimeRequest(move_tab)
  -> runtime canonical reorder -> tab_moved
  -> entrypoints/AttachedClient.handleServerMessage
  -> tab_moves.apply
     -> consume and verify exact move continuation
     -> Model.applyTabPosition
  -> adapter observes presentation revisions
```

Source and anchor must belong to the projected workspace. A request at an
apparent edge is still sent because runtime order is authoritative. The fixed
outbox/tracker retain values only, with at most one pending tab operation; no
UI/model pointer crosses the asynchronous boundary.

## Pointer interaction

Both adapters capture a primary-button press on a delivered tab and select it.
The gesture retains that tab's identity through drag and release. A normal
click does not move it. Dragging sends one anchored request on release, even
when crossing several tabs. Escape, a removed source, a workspace change,
a modal or an outside drop cancels the move; the release remains consumed.
The gesture never reaches the child terminal.

The TUI uses delivered cell rectangles and starts dragging after one cell of
movement. Its accent marker shows the insertion edge. Prepared or failed
frames cannot publish new tab targets.

The GUI uses native pixel targets and a four-logical-pixel threshold. The
held tab follows the pointer above its neighbours; the neighbours slide into
the preview order to open a gap. Hit testing retains the delivered slots from
the press so an animated label cannot change the destination under a stationary
pointer. The preview changes only presentation, never the client model. A
successful drop retains the preview while the canonical request is pending.
Failure or cancellation returns the tabs to their confirmed positions.

GUI positions use a 180 ms cubic ease-out transition, retargeted from the
current position when direction changes. All tabs share the existing frame
clock and its 60 Hz deadline. Hidden tabs retire their motion state; completed
transitions request no further frames. Keyboard and externally confirmed
reordering use the same position animation.

## Canonical result and failure

The runtime resolves source and anchor before mutation, shifts intervening
entries while preserving their relative order, and publishes a canonical
absolute position. Missing identities fail without mutation. Edge/self moves
return the current position successfully. Other observing clients get resync.

`tab_moves.apply` consumes correlation once and checks its type and exact
location before committing the runtime position. Active identity remains fixed.
Changed order advances only the tab revision; repeated positions are no-ops.
Unknown, incompatible, mismatched, replayed or invalid-position replies cannot
change order. A correlated failure keeps the old order and publishes an owned
notice. Reconnect reads canonical order instead of replaying the request.

Source: `src/client/operations/tabs/tab_moves.zig`,
`src/gui/widgets/interaction/tab_drag.zig`, and adapter tab-drag input.
Tests: `src/frontend/client/tests/tab_lifecycle.zig`,
`src/gui/tests/widget_interaction.zig`, `src/gui/widgets/TabMotions.zig`, shared
model tests and runtime workspace-order tests. `tools/gui_tab_drag.py` exercises
native gestures and reconnect against an isolated runtime.
