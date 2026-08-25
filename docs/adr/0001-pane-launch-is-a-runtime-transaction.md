---
status: accepted
---

# Treat pane launch as a runtime transaction

A pane outlives any client connection, so client attachment and response
delivery cannot decide whether it exists. The runtime commits a pane launch
only after it owns the pane and both long-lived pane actors are active. A
failure before that point aborts only the launch and never stops the runtime.

## Decision

`Server` owns the launch transaction and returns either a `running` pane or an
error. `PaneStore` owns every spawned pane allocation while the launch moves
from `starting` to `running` or `aborting`. Discovery and attachment expose only
`running` panes.

The runtime schedules `waitPane` before `readPane`. If a later launch step
fails, it marks the pane `aborting`, revokes its proxy credential, shuts down
the PTY, and retains the allocation until the child is reaped and no actor can
access it. A consumed `PaneKey` is never reused.

A workspace or tab created for the first pane remains provisional until
`Server` commits the pane. Failure removes the provisional container and any
geometry lease acquired for it. After commit, attachment or response delivery
failure removes neither the pane nor its container. Reconnection discovers the
committed pane from runtime state and never replays the launch automatically.

Pre-commit failures keep the existing protocol categories: `resource_limit`,
`invalid_request`, and `spawn_failed`. Internal phase and cause stay in
diagnostics and history.

History stores a process-spawned, aborted launch in a dedicated
`launch_attempt` record. It creates a normal `session` record only after launch
commit. This keeps `session` synonymous with a pane that became usable.

## Considered options

- Extending the transaction through client response delivery would make
  disposable client state control a runtime-owned PTY. Delivery can also fail
  after the runtime has sent the response, so it cannot define commit.
- Committing with one missing actor would publish a pane whose output or child
  exit is no longer managed.
- Stopping the runtime after partial actor startup would let one client request
  terminate every pane.
- A separate pending-launch store would duplicate ownership and event lookup
  already provided by `PaneStore`.
- Recording an aborted launch as a session would make failed startup look like
  normal terminal activity.

## Consequences

Pane IDs may contain gaps. Client confirmation can be lost even though the pane
exists, and snapshot reconciliation is the recovery path. SQLite gains a
`launch_attempt` table, while `session` starts at runtime commit.

Tests must inject failure at every launch phase and allocation point. They must
prove that the runtime survives, only `running` panes are discoverable, every
child is reaped, credentials and geometry leases are released, provisional
containers roll back, one launch attempt is recorded, and reconnect does not
create a duplicate pane.
