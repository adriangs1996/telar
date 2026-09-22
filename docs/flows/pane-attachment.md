# Pane attachment

The runtime owns pane existence and its per-client attachment. The client flag
records whether this connection can accept frames and send pane input; changing
that flag alone does not advance a presentation revision.

```text
AttachedClient.applyTabSnapshot / host resize / pane geometry or focus change
  -> resolve tab and area; require canonical membership
  -> AttachedClient.attachVisiblePanes: detached, visible, no pending attachment
  -> AttachedClient.sendRuntimeRequest(open_pane, exact pane and tab continuation)
  -> runtime attachment -> pane_opened
  -> AttachedClient.handleServerMessage
  -> AttachedClient.completePaneOpen
  -> AttachedClient.confirmPaneAttachment -> Model.confirmPaneAttachment
```

`AttachedClient.completePaneOpen` consumes correlation once and routes its typed
continuation. Confirmation requires the same pane and tab, and `created=false`.
The model accepts only a still-detached pane in the active tab. A switched tab,
retired pane or repeated confirmation cannot revive the attachment.

Tab retirement calls `AttachedClient.detachTab` with a stable `TabLocation`:

```text
Model.planTabDetachment
  -> finish tab-owned captured paste
  -> clear tab-owned reported focus
  -> each pane: detach -> retire pending continuation -> hide graphics
  -> Model.commitTabDetachment
```

The bounded plan captures pane flags and paste/focus ownership. Pending opens
also require a detach: socket order ensures runtime retirement follows that
open even if its confirmation has not arrived. Late responses resolve through
an ignored continuation. Attachment flags and pending frame IDs commit only
after all per-tab effects succeed. No presentation revision advances.

A partial failure retains already delivered paste, focus, detach and graphics
effects without claiming the whole tab detached. The client error path drops
this disposable replica; runtime pane processes remain alive.

`AttachedClient.failRuntimeRequest` sends a missing-pane rejection to
`AttachedClient.recoverPaneAttachment`. Recovery requests a coalesced tab snapshot only
when the same pane is still detached in the active tab. `AttachedClient.recoverTabSnapshot`
owns singleton snapshot coalescence. Canonical membership decides whether to
remove the pane. An internal attachment failure reports the error without an
immediate retry: an identical snapshot could otherwise repeat the same failure
indefinitely. A later resync, selection or reconnect can retry.

The flow uses fixed request/outbox capacity and at most one pending attachment
per pane. Tests in `src/frontend/client/tests/pane_lifecycle.zig`,
`synchronization.zig` and `notifications_and_agents.zig` cover real correlation,
late responses, ordering, recovery and failed recovery delivery. Model tests
in `src/model/state/tests/panes.zig` and `tabs.zig` cover exact plans and
active-only confirmation.
