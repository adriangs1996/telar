# Tab move

The runtime owns tab order. Keyboard input sends a direction; pointer release
sends captured source/anchor identities and before/after placement. Neither
predicts the canonical absolute position.

```text
actions.executeAction or window tab drag release
  -> tab_move.requestTabMove
     -> pending-operation gate, resolve source and optional anchor
     -> runtime_io.sendRuntimeRequest(move_tab)
  -> runtime canonical reorder -> tab_moved
  -> runtime_messages.handleServerMessage
  -> tab_move.completeTabMove
     -> consume and verify exact move continuation
     -> tab_move.applyPosition -> tab_move.move
  -> adapter observes presentation revisions
```

Source and anchor must belong to the projected workspace. A request at an
apparent edge is still sent because runtime order is authoritative. The fixed
outbox/tracker retain values only, with at most one pending tab operation; no
UI/model pointer crosses the asynchronous boundary.

## Pointer interaction

The window captures a primary-button press on a delivered tab and selects it.
The gesture retains that tab's identity through drag and release. A normal
click does not move it. Dragging sends one anchored request on release, even
when crossing several tabs. Escape, a removed source, a workspace change,
a modal or an outside drop cancels the move; the release remains consumed.
The gesture never reaches the child terminal.

The window uses native pixel targets and a four-logical-pixel threshold. The
held tab follows the pointer above its neighbours; the neighbours slide into
the preview order to open a gap. Hit testing retains the delivered slots from
the press so an animated label cannot change the destination under a stationary
pointer. The preview changes only presentation, never the client model. A
successful drop retains the preview while the canonical request is pending.
Failure or cancellation returns the tabs to their confirmed positions.

Tab positions use a 180 ms cubic ease-out transition, retargeted from the
current position when direction changes. All tabs share the existing frame
clock and its 60 Hz deadline. Hidden tabs retire their motion state; completed
transitions request no further frames. Keyboard and externally confirmed
reordering use the same position animation.

## Canonical result and failure

The runtime resolves source and anchor before mutation, shifts intervening
entries while preserving their relative order, and publishes a canonical
absolute position. Missing identities fail without mutation. Edge/self moves
return the current position successfully. Other observing clients get resync.

`tab_move.completeTabMove` consumes correlation once and checks its type and exact
location before committing the runtime position. Active identity remains fixed.
Changed order advances only the tab revision; repeated positions are no-ops.
Unknown, incompatible, mismatched, replayed or invalid-position replies cannot
change order. A correlated failure keeps the old order and publishes an owned
notice. Reconnect reads canonical order instead of replaying the request.

Source: `src/client/workspace/tab_move.zig`, `src/model/workspace/tab_move.zig`,
and `src/gui/widgets/interaction/tab_drag.zig`.
Tests: `src/client_tests/tab_lifecycle.zig`,
`src/gui/tests/widget_interaction.zig`, `src/gui/widgets/TabMotions.zig`, shared
model tests and runtime workspace-order tests. `tools/gui_tab_drag.py` exercises
native gestures and reconnect against an isolated runtime.
