# Resync required

When a bounded runtime response queue cannot retain a canonical tab change,
it records the affected workspace instead of blocking runtime work. Pending
management replies precede the fixed resync message, which records workspace
closure and a surviving canonical predecessor when applicable.

```text
runtime_messages.handleServerMessage(.resync_required)
  -> resync_required.applyResyncRequirement
     -> surviving workspace: verify identity, coalesce or request snapshot
     -> closed workspace: forget bookmark, request predecessor or return exit
```

The concrete operation reads `Client` state and performs the decision
and request directly. Its four results are `coalesced`, `snapshot_requested`,
`handoff_requested` and `exit`. Server dispatch maps only `exit` to status zero.

A surviving-workspace notice must match the current projection. Missing or
mismatched identity returns `UnexpectedResync` without effects. A pending
workspace snapshot coalesces the notice. Otherwise
`workspace_list_snapshot.requestWorkspaceSnapshot` registers one continuation in
`model.request_lifecycle` and queues one request; failed enqueue removes its correlation so a later
notice can retry. Requesting repair changes no model revision and schedules
no draw. The correlated reply enters `workspace_list_snapshot.applyWorkspaceSnapshot`.

Closure first forgets the invalid bookmark through
`model.navigation_history.forget`. With a predecessor it calls
`workspace_handoff.requestWorkspace`, whose admission, capacity, ordered
retirement, repair and departure rules still apply. Failure leaves the closed
bookmark forgotten. Without a predecessor it returns exit without mutating the
model merely to draw a final frame.

The wire, tracker, outbox and history use their existing fixed bounds. Resync
adds no queue or timer. Client death drops outstanding conversations; runtime
membership survives and a fresh client can reconstruct its projection.

Source: `src/client/connection/resync_required.zig` and
`src/model/connection/RequestLifecycle.zig`.
Tests: `src/frontend/client/tests/synchronization.zig` and `tab_lifecycle.zig`
cover matching identity, coalescence, full-outbox retry, closed-bookmark retention
on failure, predecessor handoff and exit. Runtime response-queue and schema
tests cover bounded loss reporting and valid closure/predecessor payloads.
