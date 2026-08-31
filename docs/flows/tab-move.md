# Tab move

The runtime owns tab order. The client sends a direction for its active tab and
waits for the runtime to return the canonical absolute position.

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
active tab identity
        |
move_tab request and typed continuation
        |
runtime socket
```

The request handler rejects another pending tab operation and requires an
active tab. It sends the active location and requested direction through a
port. It does not reorder the client model or advance a version.

The client adapter allocates the request identity, records the expected tab
location and constructs the protocol message. It still sends a request when a
tab appears to be at an edge. The runtime owns the current order and decides
whether the move changes it.

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

- `src/frontend/client/tab_moves.zig` proves one-time response correlation,
  exact identity validation, wire translation and protocol error mapping.
- `src/frontend/client/application/move_tab.zig` proves request gating, absence
  of provisional mutation, delivery failure and canonical confirmation.
- `src/frontend/client/model.zig` proves exact workspace, tab and position
  validation plus model version changes.
- `src/frontend/client/client_test.zig` proves wire correlation, failure
  behavior and presenter scheduling.
- `src/backend/runtime/commands/move_tab.zig` proves aggregate commit ordering
  and edge behavior.
- `src/backend/runtime/controllers/move_tab.zig` proves protocol translation
  and expected runtime failures.
