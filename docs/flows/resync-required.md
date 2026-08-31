# Resync required

The runtime sends `schema.resync_required` when a bounded client response queue
cannot retain a canonical tab change. Delivery records one affected workspace
instead of blocking runtime work. It sends pending management replies first,
then emits the fixed-size resync message with the workspace closure state and
its canonical predecessor when one survives.

## Client boundary

```text
schema.resync_required
        |
server_messages.handleServerMessage
        |
resync_requirements.apply
        |
current projection + pending snapshot -> typed Command
        |
HandleResyncRequiredHandler
        |
coalesce, request snapshot, request handoff, or exit
```

`resync_requirements.apply` is the protocol adapter. It reads the current
workspace identity and whether the fixed request tracker already contains a
workspace snapshot. It also connects the handler to navigation history,
snapshot delivery and the existing workspace handoff use case.

`HandleResyncRequiredHandler` owns the client policy. It does not know
`Client`, request IDs, the outbox or presentation. It returns one of four
outcomes:

- `coalesced` means an equivalent workspace snapshot is already in flight.
- `snapshot_requested` means the client queued canonical reconciliation.
- `handoff_requested` means the runtime removed the workspace and supplied a
  surviving predecessor.
- `exit` means the runtime has no workspace left for this client to follow.

The event loop maps only `exit` to process status `0`.

## Current workspace reconciliation

A resync for a surviving workspace must name the client's current projection.
A missing or different projection is `UnexpectedResync` and produces no
effect. A matching request queues one `request_workspace_snapshot` unless the
tracker already contains that request group. Repeated requirements then
coalesce without allocating another request ID or outbox entry.

The request itself does not mutate `ClientModel.Version` and does not ask for a
draw. The correlated workspace snapshot follows the normal
`ApplyWorkspaceSnapshotHandler` path. The presenter observes only the version
committed by that later canonical reconciliation.

## Closed workspace

When the runtime reports that the workspace disappeared, the handler first
forgets its navigation bookmark. The bookmark is invalid runtime identity and
stays forgotten if the next effect fails.

If the message contains a predecessor, the handler delegates to the existing
workspace handoff request. That use case owns detach ordering, local recovery,
model departure and resource release. If no predecessor survives, the handler
returns `exit` after forgetting the bookmark. It does not mutate the model just
to render a final frame that the client will never present.

## Bounds and lifetime

The wire message contains only fixed-size values. The flow adds no queue,
timer or allocation. It reuses the request tracker bounded by
`schema.max_panes_per_tab + 8`, the outbox bounded by
`schema.max_panes_per_tab + 16`, and navigation history bounded by
`schema.max_workspace_list_entries`.

All of that state belongs to the disposable client. Client death drops pending
snapshot and handoff conversations. The runtime keeps canonical workspace,
tab and pane state, so a new client can rebuild its projection.

## Proof

- `src/frontend/client/application/resync_required.zig` proves workspace
  validation, snapshot coalescence, closure policy, effect order and failure
  retention.
- `src/frontend/client/resync_requirements.zig` owns client-state translation
  and concrete snapshot, history and handoff effects.
- `src/frontend/client/client_test.zig` proves bounded request delivery,
  mismatched-workspace rejection, predecessor handoff, final exit and presenter
  silence through the real adapters.
- `src/backend/runtime/response_queue.zig` and
  `src/backend/runtime/delivery.zig` prove bounded loss accounting and resync
  wire order.
- `src/core/schema/root.zig` proves closure and predecessor validation.
