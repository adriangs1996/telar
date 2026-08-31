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
pane_openings.apply -> ConfirmPaneAttachmentHandler
        |
ClientModel.confirmPaneAttachment
```

`tab_snapshots.applyReconciliation` sends at most one attachment request per
pane. The request tracker stores the pane ID and exact tab location. A matching
`pane_opened` response must identify the same existing pane, the same location
and `created = false`. `pane_openings.apply` consumes that correlation once,
translates the protocol response and delivers only the attachment command.

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
only permits subsequent frame messages, so neither the response controller nor
the use case requests a draw and the presenter observes no model change.

## Tab attachment retirement

```text
tab selection, creation, close, handoff or client detach
        |
tab_attachments adapter
        |
RetireTabAttachmentsHandler
        |
ClientModel.planTabDetachment
        |
finish tab-owned paste -> clear tab-owned focus
        |
detach_pane -> retire continuation -> hide graphics, in pane order
        |
ClientModel.commitTabDetachment
```

The model captures an exact fixed-capacity plan by `TabLocation`. It includes
the pane identities and attachment flags plus whether that tab owns the current
paste or reported focus. Callers no longer pass mutable tab pointers across the
application boundary.

The handler composes the existing `PanePasteHandler` and
`PaneFocusReportingHandler`, preserving their identity and protocol rules. It
then detaches both confirmed attachments and panes with an attachment request
still in flight. Each detach enters transport before its continuation is
retired and its graphics become hidden. Only after every effect succeeds does
the model validate the unchanged plan, clear attachment flags and retire
pending frame IDs. This operational commit advances no presentation revision.

A failure preserves all earlier irreversible effects. Paste and focus may
already be retired, and earlier detach messages or graphics changes remain
valid. The tab attachment commit itself is deferred, so a partial delivery
cannot claim that every pane detached. The client error path destroys this
disposable replica; runtime panes remain canonical.

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
reuses the singleton tab snapshot group and adds no queue or timer. Tab
retirement uses one `TabDetachmentPlan` with the same pane bound and allocates
nothing.

- `frontend/client/application/attach_pane.zig` checks exact confirmation,
  stale success, recovery gating and effect failure.
- `frontend/client/application/tab_attachment_retirement.zig` proves paste,
  focus, pane and commit ordering, pending attachment retirement, idempotence
  and partial failures.
- `frontend/client/model.zig` checks active-only confirmation, detached-state
  queries, exact bounded detachment plans and absence of presentation
  revisions.
- `frontend/client/tab_attachments.zig` binds transport, continuation and
  graphics effects without owning the lifecycle policy.
- `frontend/client/client_test.zig` checks wire correlation, presenter silence,
  canonical missing-pane recovery and non-retrying internal failure.
- `backend/runtime/commands/open_pane.zig` and
  `backend/runtime/controllers/open_pane.zig` check runtime attachment ordering
  and failure mapping.
