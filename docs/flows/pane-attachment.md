# Pane attachment

The runtime owns pane existence and one attachment per connected client. The
client keeps only the disposable fact that its active pane is attached. That
fact gates incoming frames but does not change the visible model by itself.

## Flow

```text
ApplyTabSnapshotHandler
        |
ReconciliationEffects finds a detached pane
        |
schema.open_pane target=pane -> runtime socket
        |
open_pane.Controller -> OpenPaneHandler
        |
prepare view -> attach client -> PendingPaneOpened
        |
schema.pane_opened -> client socket
        |
handlePaneOpened -> ConfirmPaneAttachmentHandler
        |
ClientModel.confirmPaneAttachment
```

`tab_snapshots.applyReconciliation` sends at most one attachment request per
pane. The request tracker stores the pane ID and exact tab location. A matching
`pane_opened` response must identify the same existing pane, the same location
and `created = false`.

## Client commit

`ConfirmPaneAttachmentHandler` validates the runtime confirmation before it
calls `ClientModel.confirmPaneAttachment`. The model commits only when the pane
is still detached in the active tab. A tab switch, pane exit, canonical removal
or repeated confirmation makes the response stale and harmless.

Tab detachment retires a pending attachment continuation and still sends
`detach_pane` for it. The socket preserves request order, so the runtime either
detaches an attachment it has already created or processes the detach after the
pending open. A late confirmation then resolves as `ignored` and cannot revive
the client flag. Pane exit retires the pending attachment for the same reason.

Attachment confirmation advances no `ClientModel.Version`. The pane already
entered the visible layout through its canonical tab snapshot. Confirmation
only permits subsequent frame messages, so `handlePaneOpened` does not request
a draw and the presenter observes no model change.

## Failure and recovery

An explicit pane attachment can report `pane_not_found` when runtime membership
changed after the snapshot. `request_failures.apply` correlates the response,
then `HandleRequestFailureHandler` delegates that case to
`RecoverPaneAttachmentHandler`. Recovery requests one coalesced tab snapshot
only if the same pane is still detached in the active tab. The snapshot, rather
than the failed client request, decides whether to remove the pane.

An internal attachment failure does not request an immediate snapshot. An
identical snapshot would issue the same attachment again and could create an
unbounded retry loop. The client keeps the detached pane, shows the failure and
waits for a later resync, tab selection or reconnect.

Late success or failure for a continuation retired by canonical state is
ignored without scheduling a frame.

## Bounds and proof

Reconciliation issues at most one pending attachment per pane. The request
tracker uses fixed storage bounded by `schema.max_panes_per_tab`. Recovery
reuses the singleton tab snapshot group and adds no queue or timer.

- `frontend/client/application/attach_pane.zig` checks exact confirmation,
  stale success, recovery gating and effect failure.
- `frontend/client/model.zig` checks active-only confirmation, detached-state
  queries and absence of presentation revisions.
- `frontend/client/client_test.zig` checks wire correlation, presenter silence,
  canonical missing-pane recovery and non-retrying internal failure.
- `backend/runtime/commands/open_pane.zig` and
  `backend/runtime/controllers/open_pane.zig` check runtime attachment ordering
  and failure mapping.
