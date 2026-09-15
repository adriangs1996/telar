# Tab move

The runtime owns tab order. Keyboard moves send a direction for the active tab.
Pointer drops send the captured tab identity, an anchor tab, and whether to
insert before or after it. Both wait for the canonical absolute position.

This is an interactive flow. Its request and response contain only fixed-size
schema values. The client stores them in its bounded outbox and continuation
tracker, with at most one pending tab operation. No borrowed model or UI
pointer crosses the asynchronous boundary.

## Request

```text
move-tab action
        |
RequestTabMoveHandler
        |
active or captured tab identity
        |
move_tab request and typed continuation
        |
runtime socket
```

The request handler rejects another pending tab operation and requires an
active or explicitly captured tab in the current workspace. An optional
`relative_to` anchor must belong to that same workspace. It sends the location,
direction and anchor through a port. It does not reorder the client model or advance a version.

The client adapter allocates the request identity, records the expected tab
location and constructs the protocol message. It still sends a request when a
tab appears to be at an edge. The runtime owns the current order and decides
whether the move changes it.

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

## Runtime command

```text
MoveTabController
        |
MoveTabHandler
        |
workspace.moveTab
        |
TabMoved event and tab_moved response
```

The application handler commits through the workspace aggregate before it
publishes `TabMoved`. The controller maps a missing workspace or tab to
`request_failed`. A successful response contains an absolute position, which
is the only position the client accepts as canonical.

Anchored moves resolve both identities in the aggregate before mutating it.
They shift intervening entries, preserving every other tab's relative order.
A missing anchor fails without a mutation or success event.

At either edge, the runtime returns the current position as a successful
result. This keeps edge behavior under runtime authority and gives every
request one terminal response.

The requesting client receives `tab_moved`. The runtime marks other clients
that observe the workspace for resynchronization, so they rebuild the order
from a workspace snapshot instead of receiving another client's request
identity.

## Confirmation and presentation

```text
tab_moved(move_tab continuation)
        |
tab_moves.apply
        |
validate exact tab identity
        |
ConfirmTabMoveHandler
        |
ClientModel.applyTabPosition
        |
presentation_lifecycle.observe
```

The dispatcher only delegates the decoded response. `tab_moves.apply` consumes
the continuation, requires its `move_tab` type, verifies the exact location and
translates the wire payload before invoking `ConfirmTabMoveHandler`. The
confirmation handler applies only the absolute runtime position. Reordering
preserves the active tab identity and advances only the tab collection version.

A repeated position is a semantic no-op. It leaves every model version
unchanged, so `Presenter` schedules no frame. A changed position reaches the
presenter when `client_events` observes the new model version. Neither move
use case invalidates the view or requests a draw.

A correlated `request_failed` leaves tab order and model versions unchanged.
The client reports the runtime message through its notification flow. An
unknown request, another continuation type, a mismatched location or a
canonical position the model cannot accept becomes `UnexpectedTabMoved`.
Once found, the continuation is consumed before these checks, so a rejected or
replayed response cannot change order later. Reconnection rebuilds the ordered
client replica from the canonical workspace snapshot, so an interrupted client
never has to replay a move.

## Proof

- `src/client/controllers/tabs/tab_moves.zig` proves one-time response correlation,
  exact identity validation, wire translation and protocol error mapping.
- `src/client/application/tabs/move_tab.zig` proves request gating, absence
  of provisional mutation, delivery failure and canonical confirmation.
- `src/client/model/Model.zig` proves exact workspace, tab and position
  validation plus model version changes.
- `src/frontend/client/tests/` proves wire correlation, failure
  behavior and presenter scheduling.
- `src/backend/runtime/application/commands/move_tab.zig` proves aggregate commit ordering
  and edge behavior.
- `src/backend/runtime/entrypoints/requests/move_tab.zig` proves protocol translation
  and expected runtime failures.

- `src/backend/workspace/workspace_support.zig` covers long moves in both
  directions, adjacent/self no-ops and missing anchors.
- `src/gui/tests/widget_interaction.zig` covers native drag ownership, the
  canonical request and cancellation without pane input.
- `src/gui/widgets/TabMotions.zig` covers continuous retargeting and timer parking.
- `tools/gui_tab_drag.py` exercises real AppKit gestures against an isolated
  runtime, verifies order in both directions and after reconnect, and captures
  the native strip. Run `python3 tools/gui_tab_drag.py zig-out/bin/telar /tmp/telar-tab-review`.
