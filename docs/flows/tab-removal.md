# Tab removal

The client requests closure but removes a tab only after a canonical runtime
fact. The same path handles the lifecycle event after a tab loses its final
pane.

```text
AttachedClient.executeAction
  -> AttachedClient.requestTabClose
     -> pending-operation gate and active location
     -> reserve close/recovery IDs and outbox capacity
     -> AttachedClient.detachTab
     -> AttachedClient.sendRuntimeRequest(close_tab)

runtime tab_closed
  -> AttachedClient.handleServerMessage
  -> AttachedClient.completeTabClose
     -> correlate explicit reply or classify lifecycle event
     -> Model.removeTab
     -> retire requests and exact pane resources
     -> synchronize successor / follow predecessor / exit
  -> adapter observes presentation revisions
```

Before provisional detachment the request checks capacity for paste-end,
focus-out, every attached or pending-open pane detach, and the close message.
It also reserves enough request identities for closure and synchronous repair.
`AttachedClient.tabDetachmentCapacity` is shared with workspace handoff. Failure at
this stage changes neither focus nor attachment state.

The operation then detaches and queues `close_tab` without changing semantic
membership. A partial local failure requests a coalesced canonical tab snapshot.
A runtime rejection reaches `AttachedClient.recoverTabClose` before its notification;
repair is needed only while that tab is still active. Selecting an inactive
rejected tab later requests the normal snapshot.

The runtime removes the canonical tab, closes its panes and publishes removal.
Reply pressure cannot undo that state. Removing the last tab also records
workspace closure and a surviving predecessor. Other clients receive resync
instead of another client's correlation.

An unsolicited `tab_closed` uses `RequestId.none`. Explicit replies consume the
exact close continuation; retired requests are ignored. Model validation
precedes cleanup. A stale lifecycle event is idempotent and only retires
obsolete continuations. A real removal releases each exact pane's resources.
Inactive removal does not disturb active focus. Active removal silently retires
obsolete focus, exposes its successor, synchronizes resources and requests its
snapshot unless one is already pending.

Workspace closure forgets the bookmark. A surviving predecessor is followed
through `AttachedClient.requestWorkspaceSwitch`, whose bypass of stale pending
requests requires an already empty projection. With no predecessor, the
operation returns `exit`; server dispatch maps it to process status zero.

The final-pane runtime path waits until actors and attachments release the pane
before collection. It then publishes the same removal fact. A full response
queue records bounded resync state instead of blocking child work.

Canonical state survives any later client resource error. Reconnect rebuilds
the projection. The flow uses bounded tab/pane stores, request tracking and
outbox capacity, and never schedules presentation directly.

Source: `src/client/AttachedClient.zig` and `src/client/model/Model.zig`.
Tests: `src/frontend/client/tests/tab_lifecycle.zig` and `synchronization.zig`
cover preflight, partial failures, correlation, late replies, exact cleanup,
predecessor following and exit. Model and runtime transport tests cover
canonical validation and both requested/natural lifecycle triggers.
